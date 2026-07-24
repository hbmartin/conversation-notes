import ComposableArchitecture
import Foundation

/// A single MSL↔HCP interaction, from recording through interview.
///
/// Only compliance-safe artifacts are ever persisted here: the prose summary and the consent
/// utterance. Raw audio and transcripts live in transient storage owned by `AudioStorageClient`
/// and `TranscriptVaultClient` and are destroyed as the pipeline advances.
struct Session: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var kind: SessionKind = .conversation
  var startDate: Date
  var duration: TimeInterval = 0
  var state: SessionState
  var summary: String?
  var consentUtterance: String?
  var interviewID: UUID?
  var lossReason: String?
  /// Durable queue failure state. Optional so sessions written by older app versions continue to
  /// decode without a migration.
  var summarizationFailure: SummarizationFailure? = nil
  /// Audit correlation returned by the service that produced the retained summary.
  var summaryServiceAudit: ServiceAuditMetadata? = nil
}

enum SessionKind: String, Codable, Equatable, Sendable {
  case conversation
  case interview
}

extension Session {
  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case startDate
    case duration
    case state
    case summary
    case consentUtterance
    case interviewID
    case lossReason
    case summarizationFailure
    case summaryServiceAudit
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(UUID.self, forKey: .id)
    self.kind = try container.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .conversation
    self.startDate = try container.decode(Date.self, forKey: .startDate)
    self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
    self.state = try container.decode(SessionState.self, forKey: .state)
    self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
    self.consentUtterance = try container.decodeIfPresent(String.self, forKey: .consentUtterance)
    self.interviewID = try container.decodeIfPresent(UUID.self, forKey: .interviewID)
    self.lossReason = try container.decodeIfPresent(String.self, forKey: .lossReason)
    self.summarizationFailure = try container.decodeIfPresent(
      SummarizationFailure.self,
      forKey: .summarizationFailure
    )
    self.summaryServiceAudit = try container.decodeIfPresent(
      ServiceAuditMetadata.self,
      forKey: .summaryServiceAudit
    )
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.id, forKey: .id)
    try container.encode(self.kind, forKey: .kind)
    try container.encode(self.startDate, forKey: .startDate)
    try container.encode(self.duration, forKey: .duration)
    try container.encode(self.state, forKey: .state)
    try container.encodeIfPresent(self.summary, forKey: .summary)
    try container.encodeIfPresent(self.consentUtterance, forKey: .consentUtterance)
    try container.encodeIfPresent(self.interviewID, forKey: .interviewID)
    try container.encodeIfPresent(self.lossReason, forKey: .lossReason)
    try container.encodeIfPresent(self.summarizationFailure, forKey: .summarizationFailure)
    try container.encodeIfPresent(self.summaryServiceAudit, forKey: .summaryServiceAudit)
  }
}

struct SummarizationFailure: Codable, Equatable, Sendable {
  var kind: Kind
  var attemptCount: Int
  var nextRetryAt: Date?
  var requiredAction: RequiredAction

  enum Kind: String, Codable, Equatable, Sendable {
    case credentialsMissing
    case credentialsRejected
    case network
    case rateLimited
    case serviceUnavailable
    case requestRejected
    case invalidResponse
    case refusal
    case truncation
    case transcriptUnavailable
    case unknown

    fileprivate var conversationServiceError: ConversationServiceError? {
      switch self {
      case .credentialsMissing:
        return .credentialsMissing
      case .credentialsRejected:
        return .credentialsRejected
      case .network:
        return .network
      case .rateLimited:
        return .rateLimited(retryAfterSeconds: nil)
      case .serviceUnavailable:
        return .serviceUnavailable
      case .requestRejected:
        return .requestRejected
      case .invalidResponse:
        return .invalidResponse
      case .refusal:
        return .contentRefused
      case .truncation:
        return .responseTruncated
      case .unknown:
        return .unknown
      case .transcriptUnavailable:
        return nil
      }
    }
  }

  enum RequiredAction: String, Codable, Equatable, Sendable {
    case automaticRetry
    case openSettings
    case retryNow
    case contactSupport
  }

  var userMessage: String {
    if self.kind == .transcriptUnavailable {
      return "The encrypted transcript could not be loaded. Contact support."
    }
    return self.kind.conversationServiceError?.userMessage
      ?? ConversationServiceError.unknown.userMessage
  }
}

enum SessionState: String, Codable, Equatable, Sendable {
  /// Audio file growing in the staging directory.
  case recording
  /// Audio on disk, waiting for the power gate or a transcription retry.
  case stopped
  /// On-device transcription in progress.
  case transcribing
  /// Transcript secured in the encrypted vault; audio destroyed. Queued for cloud summarization.
  case awaitingSummarization
  /// Summary and consent field stored; transcript destroyed.
  case summaryReady
  /// Post-conversation operator interview in progress.
  case interviewing
  /// Interview complete; all retained artifacts saved.
  case saved
  /// The operator denied microphone access before recording began.
  case permissionDenied
  /// Terminal: the recording was interrupted before transcription completed; artifacts purged.
  case lost
}

extension Session {
  var isAwaitingInterview: Bool { state == .summaryReady }
  var isPendingSummarization: Bool { state == .awaitingSummarization }
}

extension SharedKey where Self == FileStorageKey<IdentifiedArrayOf<Session>>.Default {
  static var sessions: Self {
    Self[
      .fileStorage(
        .applicationSupportDirectory.appending(components: "MSLCapture", "sessions.json")
      ),
      default: []
    ]
  }
}
