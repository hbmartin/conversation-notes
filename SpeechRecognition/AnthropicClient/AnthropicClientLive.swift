import ComposableArchitecture
import Foundation

extension AnthropicClient: DependencyKey {
  static var liveValue: Self {
    @Sendable func post(_ body: MessagesRequest) async throws -> MessagesResponse {
      @Dependency(\.apiKeyClient) var apiKeyClient
      guard let key = try? apiKeyClient.load(), !key.isEmpty else {
        throw AnthropicClientError.missingAPIKey
      }
      var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
      request.httpMethod = "POST"
      request.setValue(key, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      request.setValue("application/json", forHTTPHeaderField: "content-type")
      // Non-streaming; large summarization responses can run long.
      request.timeoutInterval = 300
      request.httpBody = try JSONEncoder().encode(body)

      var lastError = AnthropicClientError.network
      for attempt in 0..<3 {
        if attempt > 0 {
          try await Task.sleep(for: .seconds(Double(1 << attempt) * Double.random(in: 0.5...1)))
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
          )
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
          return try JSONDecoder().decode(SummarizationResult.self, from: Data(json.utf8))
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
          )
        )
        switch response.stopReason {
        case .refusal: throw AnthropicClientError.refused
        case .maxTokens: throw AnthropicClientError.truncated
        default: break
        }
        return AssistantTurn(response: response)
      }
    )
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

  static let summaryOutputSchema = try! JSONValue(
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
      """
  )
}
