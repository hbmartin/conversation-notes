import ComposableArchitecture
import Foundation

/// Provider-neutral boundary for remote conversation processing.
///
/// Features pass domain context only. Prompt text, tool schemas, provider messages, and model
/// selection belong to the implementation so a production gateway can replace the temporary
/// direct Anthropic adapter without changing feature reducers.
@DependencyClient
struct ConversationServiceClient: Sendable {
  var summarize: @Sendable (_ request: SummaryRequest) async throws -> SummaryResponse
  var nextInterviewStep: @Sendable (_ context: InterviewContext) async throws -> InterviewStep
}

struct SummaryRequest: Equatable, Sendable {
  var sessionID: Session.ID
  var transcript: String
}

struct SummaryResponse: Equatable, Sendable {
  var summary: String
  var consentUtterance: String?
  var audit: ServiceAuditMetadata? = nil
}

struct InterviewContext: Equatable, Sendable {
  var interviewID: UUID
  var sessionID: Session.ID
  var summary: String
  var exchanges: [InterviewExchange]
}

struct InterviewExchange: Equatable, Sendable {
  var question: String
  var answer: String
}

enum InterviewStep: Equatable, Sendable {
  case question(String, audit: ServiceAuditMetadata?)
  case completed(InterviewExtraction, audit: ServiceAuditMetadata?)
}

/// Opaque identifiers retained for service-side audit correlation. A gateway implementation can
/// provide its own request, prompt, and model versions without exposing provider wire types.
struct ServiceAuditMetadata: Codable, Equatable, Sendable {
  var requestID: String?
  var modelVersion: String?
  var promptVersion: String?
}

enum ConversationServiceError: Error, Equatable, Sendable {
  case credentialsMissing
  case credentialsRejected
  case requestRejected
  case rateLimited(retryAfterSeconds: Int?)
  case serviceUnavailable
  case network
  case invalidResponse
  case contentRefused
  case responseTruncated
  case unknown

  var isRetryable: Bool {
    switch self {
    case .rateLimited, .serviceUnavailable, .network:
      return true
    case .credentialsMissing, .credentialsRejected, .requestRejected, .invalidResponse,
      .contentRefused, .responseTruncated, .unknown:
      return false
    }
  }

  var userMessage: String {
    switch self {
    case .credentialsMissing:
      return "No service credential is configured. Add one in Settings."
    case .credentialsRejected:
      return "The service credential was rejected. Check it in Settings."
    case .requestRejected:
      return "The service rejected this request. Contact support."
    case .rateLimited:
      return "The service is rate-limiting requests. It will retry automatically."
    case .serviceUnavailable:
      return "The service is temporarily unavailable. It will retry automatically."
    case .network:
      return "A network error occurred. The request will retry automatically."
    case .invalidResponse:
      return "The service returned an unexpected response. Contact support."
    case .contentRefused:
      return "The service declined to process this content. Contact support."
    case .responseTruncated:
      return "The service response was incomplete. Contact support."
    case .unknown:
      return "An unexpected service error occurred. Retry this session."
    }
  }
}

extension ConversationServiceClient: TestDependencyKey {
  static var previewValue: Self {
    let questions = LockIsolated(0)
    return Self(
      summarize: { _ in
        try await Task.sleep(for: .seconds(1))
        return SummaryResponse(
          summary: "The MSL discussed phase 3 efficacy data and subgroup analyses.",
          consentUtterance: "Yes, that's fine, go ahead.",
          audit: ServiceAuditMetadata(
            requestID: "preview-summary",
            modelVersion: "preview-model",
            promptVersion: "preview-summary-v1"
          )
        )
      },
      nextInterviewStep: { _ in
        try await Task.sleep(for: .milliseconds(600))
        let index = questions.withValue { value -> Int in
          defer { value += 1 }
          return value
        }
        let audit = ServiceAuditMetadata(
          requestID: "preview-interview-\(index)",
          modelVersion: "preview-model",
          promptVersion: "preview-interview-v1"
        )
        switch index {
        case 0:
          return .question("What is the clinician's specialty?", audit: audit)
        case 1:
          return .question("Were any adverse events or product complaints mentioned?", audit: audit)
        default:
          return .completed(
            InterviewExtraction(
              hcpSpecialty: "Cardiology",
              topicsDiscussed: ["Phase 3 efficacy data"],
              keyScientificQuestions: "Subgroup analysis methodology",
              unansweredFollowUps: "None",
              medInfoRequests: "None",
              adverseEventReported: false,
              adverseEventDetail: "",
              offLabelDiscussed: false,
              offLabelDetail: "",
              hcpSentiment: .positive,
              commitmentsNextSteps: "Send subgroup analysis publication",
              followUpNeeded: true
            ),
            audit: audit
          )
        }
      }
    )
  }

  static let testValue = Self()
}

extension DependencyValues {
  var conversationService: ConversationServiceClient {
    get { self[ConversationServiceClient.self] }
    set { self[ConversationServiceClient.self] = newValue }
  }
}
