import ComposableArchitecture
import Foundation
import Testing

@testable import SpeechRecognition

@Suite
struct AnthropicClientTests {
  // MARK: - Wire types

  @Test
  func contentBlockRoundTrip() throws {
    let json = """
      [
        {"type": "text", "text": "Hello"},
        {"type": "tool_use", "id": "toolu_1", "name": "record_interview", "input": {"a": 1}},
        {"type": "tool_result", "tool_use_id": "toolu_1", "content": "ok", "is_error": true},
        {"type": "thinking", "thinking": "hmm", "signature": "sig"},
        {"type": "some_future_block", "payload": {"nested": [1, 2]}}
      ]
      """
    let blocks = try JSONDecoder().decode([ContentBlock].self, from: Data(json.utf8))

    #expect(blocks[0] == .text("Hello"))
    #expect(
      blocks[1]
        == .toolUse(id: "toolu_1", name: "record_interview", input: .object(["a": .number(1)]))
    )
    #expect(blocks[2] == .toolResult(toolUseID: "toolu_1", content: "ok", isError: true))
    guard case .unknown = blocks[3] else {
      Issue.record("Thinking block should decode as unknown")
      return
    }
    guard case .unknown = blocks[4] else {
      Issue.record("Future block should decode as unknown")
      return
    }

    // Unknown blocks must re-encode verbatim so echoing assistant content back never corrupts
    // a turn.
    let reencoded = try JSONEncoder().encode(blocks)
    let original = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    let roundTripped = try JSONDecoder().decode(JSONValue.self, from: reencoded)
    #expect(original == roundTripped)
  }

  @Test
  func messagesRequestEncoding() throws {
    let request = MessagesRequest(
      maxTokens: 2_000,
      system: "You are an interviewer.",
      messages: [AnthropicMessage(role: .user, content: [.text("Begin.")])],
      tools: [InterviewAgent.recordInterviewTool]
    )
    let encoded = try JSONDecoder().decode(
      JSONValue.self, from: JSONEncoder().encode(request)
    )
    guard case .object(let object) = encoded else {
      Issue.record("Expected a JSON object")
      return
    }
    #expect(object["model"] == .string("claude-opus-4-8"))
    #expect(object["max_tokens"] == .number(2_000))
    guard
      case .array(let tools)? = object["tools"],
      case .object(let tool)? = tools.first,
      case .object(let schema)? = tool["input_schema"]
    else {
      Issue.record("Expected a tool with an input_schema object")
      return
    }
    #expect(tool["strict"] == .bool(true))
    #expect(tool["name"] == .string("record_interview"))
    #expect(schema["additionalProperties"] == .bool(false))
  }

  @Test
  func summarizeRequestUsesStructuredOutput() throws {
    let request = MessagesRequest(
      maxTokens: 16_000,
      system: AnthropicClient.summarizerSystemPrompt,
      messages: [AnthropicMessage(role: .user, content: [.text("transcript")])],
      outputConfig: OutputConfig(
        format: OutputConfig.Format(schema: AnthropicClient.summaryOutputSchema)
      )
    )
    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
    guard
      case .object(let object) = encoded,
      case .object(let outputConfig)? = object["output_config"],
      case .object(let format)? = outputConfig["format"]
    else {
      Issue.record("Expected output_config.format")
      return
    }
    #expect(format["type"] == .string("json_schema"))
  }

  @Test
  func summarizationResultDecodesNullConsent() throws {
    let result = try JSONDecoder().decode(
      AnthropicSummaryPayload.self,
      from: Data(#"{"summary": "A summary.", "consent_utterance": null}"#.utf8)
    )
    #expect(result.summary == "A summary.")
    #expect(result.consentUtterance == nil)
  }

  // MARK: - Response parsing / error taxonomy

  private func httpResponse(
    status: Int, headers: [String: String] = [:]
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: "https://api.anthropic.com/v1/messages")!,
      statusCode: status,
      httpVersion: nil,
      headerFields: headers
    )!
  }

  @Test
  func parseSuccessEndTurn() throws {
    let body = """
      {
        "id": "msg_1",
        "model": "claude-opus-4-8",
        "content": [{"type": "text", "text": "What is the HCP's specialty?"}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 10, "output_tokens": 12}
      }
      """
    let response = try AnthropicClient.parse(
      data: Data(body.utf8), response: httpResponse(status: 200)
    )
    #expect(response.stopReason == .endTurn)
    #expect(response.text == "What is the HCP's specialty?")
    #expect(response.firstToolUse == nil)
  }

  @Test
  func parseToolUseDecodesExtraction() throws {
    let body = """
      {
        "id": "msg_2",
        "model": "claude-opus-4-8",
        "content": [
          {
            "type": "tool_use",
            "id": "toolu_9",
            "name": "record_interview",
            "input": {
              "hcp_specialty": "Cardiology",
              "topics_discussed": ["Phase 3 data"],
              "key_scientific_questions": "Subgroups",
              "unanswered_follow_ups": "None",
              "med_info_requests": "None",
              "adverse_event_reported": true,
              "adverse_event_detail": "Patient dizziness reported",
              "off_label_discussed": false,
              "off_label_detail": "",
              "hcp_sentiment": "neutral",
              "commitments_next_steps": "Send publication",
              "follow_up_needed": true
            }
          }
        ],
        "stop_reason": "tool_use",
        "usage": {"input_tokens": 10, "output_tokens": 12}
      }
      """
    let response = try AnthropicClient.parse(
      data: Data(body.utf8), response: httpResponse(status: 200)
    )
    #expect(response.stopReason == .toolUse)
    let toolUse = try #require(response.firstToolUse)
    #expect(toolUse.name == "record_interview")
    let extraction = try JSONDecoder().decode(
      InterviewExtraction.self, from: toolUse.input.encodedData()
    )
    #expect(extraction.hcpSpecialty == "Cardiology")
    #expect(extraction.adverseEventReported)
    #expect(extraction.adverseEventDetail == "Patient dizziness reported")
    #expect(extraction.hcpSentiment == .neutral)
  }

  @Test
  func parseRefusalStopReason() throws {
    let body = """
      {
        "id": "msg_3",
        "model": "claude-opus-4-8",
        "content": [],
        "stop_reason": "refusal",
        "usage": {"input_tokens": 10, "output_tokens": 0}
      }
      """
    let response = try AnthropicClient.parse(
      data: Data(body.utf8), response: httpResponse(status: 200)
    )
    #expect(response.stopReason == .refusal)
  }

  @Test
  func parseUnauthorized() {
    #expect(throws: AnthropicClientError.unauthorized) {
      try AnthropicClient.parse(data: Data(), response: httpResponse(status: 401))
    }
  }

  @Test
  func parseInvalidRequestPropagatesMessage() {
    let body = #"{"type": "error", "error": {"type": "invalid_request_error", "message": "bad tool"}}"#
    #expect(throws: AnthropicClientError.invalidRequest("bad tool")) {
      try AnthropicClient.parse(data: Data(body.utf8), response: httpResponse(status: 400))
    }
  }

  @Test
  func parseRateLimitedReadsRetryAfter() {
    #expect(throws: AnthropicClientError.rateLimited(retryAfterSeconds: 30)) {
      try AnthropicClient.parse(
        data: Data(),
        response: httpResponse(status: 429, headers: ["retry-after": "30"])
      )
    }
  }

  @Test
  func parseServerErrors() {
    #expect(throws: AnthropicClientError.serverError(status: 529)) {
      try AnthropicClient.parse(data: Data(), response: httpResponse(status: 529))
    }
    #expect(AnthropicClientError.serverError(status: 529).isRetryable)
    #expect(AnthropicClientError.rateLimited(retryAfterSeconds: nil).isRetryable)
    #expect(AnthropicClientError.network.isRetryable)
    #expect(!AnthropicClientError.unauthorized.isRetryable)
    #expect(!AnthropicClientError.refused.isRetryable)
  }

  @Test
  func retryDelayHonorsAndCapsRetryAfter() {
    // A present Retry-After header is honored…
    #expect(
      AnthropicClient.retryDelay(
        after: .rateLimited(retryAfterSeconds: 30), attempt: 1, jitter: 1
      ) == 30
    )
    // …but clamped so a hostile or buggy header can't park the queue for hours.
    #expect(
      AnthropicClient.retryDelay(
        after: .rateLimited(retryAfterSeconds: 86_400), attempt: 1, jitter: 1
      ) == 60
    )
    // Without the header, rate limiting falls back to jittered exponential backoff.
    #expect(
      AnthropicClient.retryDelay(
        after: .rateLimited(retryAfterSeconds: nil), attempt: 2, jitter: 0.5
      ) == 2
    )
    #expect(AnthropicClient.retryDelay(after: .network, attempt: 1, jitter: 1) == 2)
    #expect(AnthropicClient.retryDelay(after: .network, attempt: 2, jitter: 1) == 4)
  }

  // MARK: - Provider-neutral adapter

  @Test
  func conversationAdapterReconstructsProviderHistoryAndMapsAudit() async throws {
    let captured = LockIsolated<InterviewTurnRequest?>(nil)
    let audit = ServiceAuditMetadata(
      requestID: "msg_42",
      modelVersion: "claude-test",
      promptVersion: "interview-v1"
    )
    let provider = AnthropicClient(
      summarize: { _ in SummaryResponse(summary: "unused", consentUtterance: nil) },
      interviewTurn: { request in
        captured.setValue(request)
        return AssistantTurn(
          content: [.text("Next question?")],
          stopReason: .endTurn,
          text: "Next question?",
          toolUse: nil,
          audit: audit
        )
      }
    )
    let client = withDependencies {
      $0.anthropicClient = provider
    } operation: {
      ConversationServiceClient.liveValue
    }

    let step = try await client.nextInterviewStep(
      InterviewContext(
        interviewID: UUID(0),
        sessionID: UUID(1),
        summary: "Scrubbed summary",
        exchanges: [InterviewExchange(question: "First?", answer: "Answer")]
      )
    )

    #expect(step == .question("Next question?", audit: audit))
    let request = try #require(captured.value)
    #expect(request.system.contains("Scrubbed summary"))
    #expect(
      request.messages
        == [
          InterviewAgent.openingUserMessage,
          AnthropicMessage(role: .assistant, content: [.text("First?")]),
          AnthropicMessage(role: .user, content: [.text("Answer")]),
        ]
    )
    #expect(request.tools == [InterviewAgent.recordInterviewTool])
  }

  @Test
  func anthropicErrorsMapToDomainErrors() {
    #expect(AnthropicClientError.missingAPIKey.conversationServiceError == .credentialsMissing)
    #expect(AnthropicClientError.unauthorized.conversationServiceError == .credentialsRejected)
    #expect(
      AnthropicClientError.rateLimited(retryAfterSeconds: 12).conversationServiceError
        == .rateLimited(retryAfterSeconds: 12)
    )
    #expect(AnthropicClientError.serverError(status: 529).conversationServiceError == .serviceUnavailable)
    #expect(AnthropicClientError.decoding("bad").conversationServiceError == .invalidResponse)
    #expect(AnthropicClientError.refused.conversationServiceError == .contentRefused)
  }
}
