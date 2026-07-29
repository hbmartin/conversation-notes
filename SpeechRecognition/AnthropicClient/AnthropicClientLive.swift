import ComposableArchitecture
import Foundation

extension AnthropicClient: DependencyKey {
  static var liveValue: Self {
    @Sendable func post(
      _ body: MessagesRequest, timeout: TimeInterval
    ) async throws -> MessagesResponse {
      @Dependency(\.apiKeyClient) var apiKeyClient
      guard let key = try apiKeyClient.resolvedKey() else {
        throw AnthropicClientError.missingAPIKey
      }
      var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
      request.httpMethod = "POST"
      request.setValue(key, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      request.setValue("application/json", forHTTPHeaderField: "content-type")
      // Non-streaming; large summarization responses can run long.
      request.timeoutInterval = timeout
      request.httpBody = try JSONEncoder().encode(body)

      var lastError = AnthropicClientError.network
      for attempt in 0..<3 {
        if attempt > 0 {
          try await Task.sleep(
            for: .seconds(
              Self.retryDelay(after: lastError, attempt: attempt, jitter: .random(in: 0.5...1))
            )
          )
        }
        do {
          let data: Data
          let response: URLResponse
          do {
            (data, response) = try await URLSession.shared.data(for: request)
          } catch {
            throw AnthropicClientError.network
          }
          return try Self.parse(data: data, response: response)
        } catch let error as AnthropicClientError where error.isRetryable {
          lastError = error
        }
      }
      throw lastError
    }

    return Self(
      summarize: { transcript in
        let response = try await post(
          MessagesRequest(
            maxTokens: 16_000,
            system: Self.summarizerSystemPrompt,
            messages: [AnthropicMessage(role: .user, content: [.text(transcript)])],
            outputConfig: OutputConfig(
              format: OutputConfig.Format(schema: Self.summaryOutputSchema)
            )
          ),
          timeout: 300
        )
        switch response.stopReason {
        case .refusal: throw AnthropicClientError.refused
        case .maxTokens: throw AnthropicClientError.truncated
        default: break
        }
        let json = response.text
        guard !json.isEmpty else {
          throw AnthropicClientError.decoding("Response contained no text block")
        }
        do {
          let result = try JSONDecoder().decode(AnthropicSummaryPayload.self, from: Data(json.utf8))
          return SummaryResponse(
            summary: result.summary,
            consentUtterance: result.consentUtterance,
            audit: ServiceAuditMetadata(
              requestID: response.id,
              modelVersion: response.model,
              promptVersion: Self.summaryPromptVersion
            )
          )
        } catch {
          throw AnthropicClientError.decoding("\(error)")
        }
      },
      interviewTurn: { turnRequest in
        let response = try await post(
          MessagesRequest(
            maxTokens: turnRequest.maxTokens,
            system: turnRequest.system,
            messages: turnRequest.messages,
            tools: turnRequest.tools
          ),
          timeout: 60
        )
        switch response.stopReason {
        case .refusal: throw AnthropicClientError.refused
        case .maxTokens: throw AnthropicClientError.truncated
        default: break
        }
        return AssistantTurn(response: response, promptVersion: Self.interviewPromptVersion)
      }
    )
  }

  /// Delay in seconds before retry `attempt` (1-based) after `error`. Pure so the backoff
  /// policy is unit-testable; `jitter` scales the exponential branch (callers pass a random
  /// value in 0.5...1).
  static func retryDelay(after error: AnthropicClientError, attempt: Int, jitter: Double) -> Double
  {
    if case .rateLimited(let seconds) = error, let seconds {
      // The header is server-controlled; trusting it verbatim could park this call for hours.
      // Longer waits belong to the summarization queue's own capped backoff.
      return min(Double(seconds), 60)
    }
    return Double(1 << attempt) * jitter
  }

  /// Pure function of (data, response) so error mapping is unit-testable without networking.
  static func parse(data: Data, response: URLResponse) throws -> MessagesResponse {
    guard let http = response as? HTTPURLResponse else {
      throw AnthropicClientError.network
    }
    switch http.statusCode {
    case 200:
      do {
        return try JSONDecoder().decode(MessagesResponse.self, from: data)
      } catch {
        throw AnthropicClientError.decoding("\(error)")
      }
    case 401:
      throw AnthropicClientError.unauthorized
    case 429:
      throw AnthropicClientError.rateLimited(
        retryAfterSeconds: http.value(forHTTPHeaderField: "retry-after").flatMap(Int.init)
      )
    case 500...:
      throw AnthropicClientError.serverError(status: http.statusCode)
    default:
      let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.message
      throw AnthropicClientError.invalidRequest(message ?? "HTTP \(http.statusCode)")
    }
  }

  static let summarizerSystemPrompt = """
    You are a medical-affairs compliance assistant. You will receive a transcript of an \
    in-person conversation between a Medical Science Liaison (MSL) and a healthcare \
    professional (HCP).

    Produce:
    1. "summary" — a prose summary of the scientific exchange suitable for a \
    compliance-reviewed medical-affairs record. Remove ALL patient identifiers and protected \
    health information: names, initials, ages, dates of birth, locations, and any \
    case-identifying details. Refer to patients generically ("a patient", "several patients"). \
    Preserve the scientific content: data discussed, questions asked, and products mentioned.
    2. "consent_utterance" — if the HCP verbally consented to being recorded anywhere in the \
    transcript, extract that sentence verbatim; otherwise null.
    """

  static let summaryOutputSchema: JSONValue = {
    do {
      return try JSONValue(
        parsing: """
          {
            "type": "object",
            "properties": {
              "summary": {
                "type": "string",
                "description": "Compliance-safe prose summary with all PHI and patient identifiers removed"
              },
              "consent_utterance": {
                "anyOf": [{"type": "string"}, {"type": "null"}],
                "description": "The HCP's verbatim consent-to-record statement, or null if none was found"
              }
            },
            "required": ["summary", "consent_utterance"],
            "additionalProperties": false
          }
          """)
    } catch {
      preconditionFailure("Invalid summary schema: \(error)")
    }
  }()

  static let summaryPromptVersion = "direct-anthropic-summary-v1"
  static let interviewPromptVersion = "direct-anthropic-interview-v1"
}

/// Temporary BYOK adapter. Production deployments replace this dependency with an authenticated
/// gateway implementation while feature reducers remain provider-neutral.
extension ConversationServiceClient: DependencyKey {
  static var liveValue: Self {
    @Dependency(\.anthropicClient) var anthropic

    return Self(
      summarize: { request in
        do {
          return try await anthropic.summarize(request.transcript)
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as AnthropicClientError {
          throw error.conversationServiceError
        } catch {
          throw ConversationServiceError.unknown
        }
      },
      nextInterviewStep: { context in
        var messages = [InterviewAgent.openingUserMessage]
        for exchange in context.exchanges {
          messages.append(AnthropicMessage(role: .assistant, content: [.text(exchange.question)]))
          messages.append(AnthropicMessage(role: .user, content: [.text(exchange.answer)]))
        }

        do {
          let turn = try await anthropic.interviewTurn(
            InterviewTurnRequest(
              system: InterviewAgent.systemPrompt(summary: context.summary),
              messages: messages,
              tools: [InterviewAgent.recordInterviewTool]
            )
          )
          if let toolUse = turn.toolUse, toolUse.name == InterviewAgent.toolName {
            do {
              let extraction = try JSONDecoder().decode(
                InterviewExtraction.self,
                from: toolUse.input.encodedData()
              )
              return .completed(extraction, audit: turn.audit)
            } catch {
              throw ConversationServiceError.invalidResponse
            }
          }
          guard turn.stopReason == .endTurn, !turn.text.isEmpty else {
            throw ConversationServiceError.invalidResponse
          }
          return .question(turn.text, audit: turn.audit)
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as ConversationServiceError {
          throw error
        } catch let error as AnthropicClientError {
          throw error.conversationServiceError
        } catch {
          throw ConversationServiceError.unknown
        }
      }
    )
  }
}
