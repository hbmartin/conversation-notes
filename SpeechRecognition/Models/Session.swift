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
