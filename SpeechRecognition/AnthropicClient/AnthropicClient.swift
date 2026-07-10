import ComposableArchitecture
import Foundation

/// The app's two uses of the Anthropic Messages API:
/// - `summarize`: one-shot, PHI-scrubbing prose summary + consent-utterance extraction of a
///   conversation transcript (the transcript transits the cloud; the accepted-risk register
///   covers this).
/// - `interviewTurn`: one turn of the post-conversation interview agent loop.
@DependencyClient
struct AnthropicClient: Sendable {
  var summarize: @Sendable (_ transcript: String) async throws -> SummarizationResult
  var interviewTurn: @Sendable (_ request: InterviewTurnRequest) async throws -> AssistantTurn
}

struct SummarizationResult: Codable, Equatable, Sendable {
  var summary: String
  var consentUtterance: String?

  private enum CodingKeys: String, CodingKey {
    case summary
    case consentUtterance = "consent_utterance"
  }
}

struct InterviewTurnRequest: Equatable, Sendable {
  var system: String
  var messages: [AnthropicMessage]
  var tools: [AnthropicTool]
  var maxTokens = 2_000
}

struct AssistantTurn: Equatable, Sendable {
  /// The full block array, echoed back verbatim into the conversation history.
  var content: [ContentBlock]
  var stopReason: StopReason
  /// Concatenated text blocks — the next question to speak, when `stopReason == .endTurn`.
  var text: String
  var toolUse: ToolUseCall?

  struct ToolUseCall: Equatable, Sendable {
    var id: String
    var name: String
    var input: JSONValue
  }
}

extension AssistantTurn {
  init(response: MessagesResponse) {
    self.content = response.content
    self.stopReason = response.stopReason
    self.text = response.text
    self.toolUse = response.firstToolUse.map {
      ToolUseCall(id: $0.id, name: $0.name, input: $0.input)
    }
  }
}

enum AnthropicClientError: Error, Equatable {
  case missingAPIKey
  case unauthorized
  case invalidRequest(String)
  case rateLimited(retryAfterSeconds: Int?)
  case serverError(status: Int)
  case network
  case decoding(String)
  case refused
  case truncated

  var isRetryable: Bool {
    switch self {
    case .rateLimited, .serverError, .network: return true
    case .missingAPIKey, .unauthorized, .invalidRequest, .decoding, .refused, .truncated:
      return false
    }
  }

  var userMessage: String {
    switch self {
    case .missingAPIKey:
      return "No API key is configured. Add one in Settings."
    case .unauthorized:
      return "The API key was rejected. Check it in Settings."
    case .invalidRequest(let message):
      return "The request was rejected: \(message)"
    case .rateLimited:
      return "The service is rate-limiting requests. Try again shortly."
    case .serverError:
      return "The service is temporarily unavailable. Try again shortly."
    case .network:
      return "A network error occurred. Check your connection."
    case .decoding:
      return "The service returned an unexpected response."
    case .refused:
      return "The service declined to process this content."
    case .truncated:
      return "The response was cut short. Try again."
    }
  }
}

extension AnthropicClient: TestDependencyKey {
  static var previewValue: Self {
    let scriptedTurns = LockIsolated<[AssistantTurn]>([
      AssistantTurn(
        content: [.text("To start, what is the specialty of the clinician you met with?")],
        stopReason: .endTurn,
        text: "To start, what is the specialty of the clinician you met with?",
        toolUse: nil
      ),
      AssistantTurn(
        content: [.text("Were any adverse events or product complaints mentioned?")],
        stopReason: .endTurn,
        text: "Were any adverse events or product complaints mentioned?",
        toolUse: nil
      ),
      {
        let input = try! JSONValue(
          parsing: """
            {
              "hcp_specialty": "Cardiology",
              "topics_discussed": ["Phase 3 efficacy data"],
              "key_scientific_questions": "Subgroup analysis methodology",
              "unanswered_follow_ups": "None",
              "med_info_requests": "None",
              "adverse_event_reported": false,
              "adverse_event_detail": "",
              "off_label_discussed": false,
              "off_label_detail": "",
              "hcp_sentiment": "positive",
              "commitments_next_steps": "Send subgroup analysis publication",
              "follow_up_needed": true
            }
            """)
        return AssistantTurn(
          content: [.toolUse(id: "toolu_preview", name: "record_interview", input: input)],
          stopReason: .toolUse,
          text: "",
          toolUse: AssistantTurn.ToolUseCall(
            id: "toolu_preview", name: "record_interview", input: input
          )
        )
      }(),
    ])
    return Self(
      summarize: { _ in
        try await Task.sleep(for: .seconds(1))
        return SummarizationResult(
          summary: """
            The MSL walked the HCP through phase 3 efficacy data. The HCP raised questions \
            about the subgroup analysis methodology and requested the related publication.
            """,
          consentUtterance: "Yes, that's fine, go ahead."
        )
      },
      interviewTurn: { _ in
        try await Task.sleep(for: .milliseconds(600))
        return scriptedTurns.withValue { turns in
          turns.isEmpty ? AssistantTurn(content: [], stopReason: .endTurn, text: "", toolUse: nil)
            : turns.removeFirst()
        }
      }
    )
  }

  static let testValue = Self()
}

extension DependencyValues {
  var anthropicClient: AnthropicClient {
    get { self[AnthropicClient.self] }
    set { self[AnthropicClient.self] = newValue }
  }
}
