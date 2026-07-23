import ComposableArchitecture
import Foundation

/// A single MSL↔HCP interaction, from recording through interview.
///
/// Only compliance-safe artifacts are ever persisted here: the prose summary and the consent
/// utterance. Raw audio and transcripts live in transient storage owned by `AudioStorageClient`
/// and `TranscriptVaultClient` and are destroyed as the pipeline advances.
struct Session: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
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
    case contentRefused
    case responseTruncated
    case transcriptUnavailable
    case unknown
  }

  enum RequiredAction: String, Codable, Equatable, Sendable {
    case automaticRetry
    case openSettings
    case retryNow
    case contactSupport
  }

  var userMessage: String {
    switch self.kind {
    case .credentialsMissing:
      return "No service credential is configured. Add one in Settings."
    case .credentialsRejected:
      return "The service credential was rejected. Check it in Settings."
    case .network:
      return "A network error interrupted summarization."
    case .rateLimited:
      return "The service is temporarily rate-limiting requests."
    case .serviceUnavailable:
      return "The summarization service is temporarily unavailable."
    case .requestRejected:
      return "The summarization request was rejected. Contact support."
    case .invalidResponse:
      return "The summarization service returned an unexpected response. Contact support."
    case .contentRefused:
      return "The service declined to summarize this content. Contact support."
    case .responseTruncated:
      return "The summarization response was incomplete. Contact support."
    case .transcriptUnavailable:
      return "The encrypted transcript could not be loaded. Contact support."
    case .unknown:
      return "An unexpected summarization error occurred."
    }
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
