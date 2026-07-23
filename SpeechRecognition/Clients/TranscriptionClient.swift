import ComposableArchitecture
import Foundation

/// The on-device transcript of a recorded conversation.
///
/// `segments` carries per-utterance detail so a future diarizing engine (the spec's later-phase
/// pyannote/sherpa pipeline) can slot in behind the same interface; the v1 Apple engine leaves
/// `speaker` nil.
struct Transcript: Codable, Equatable, Sendable {
  var fullText: String
  var segments: [Segment] = []

  struct Segment: Codable, Equatable, Sendable {
    var text: String
    var speaker: String?
    var start: TimeInterval
    var end: TimeInterval
  }
}

/// Post-hoc, on-device batch transcription of an audio file. The interface hides the engine so
/// swapping implementations (SpeechAnalyzer today, a local diarization pipeline later) never
/// touches a reducer.
@DependencyClient
struct TranscriptionClient: Sendable {
  var requestAuthorization: @Sendable () async -> Bool = { false }
  /// Downloads any on-device model assets needed for `locale`. Call while recording so the model
  /// is ready before the operator taps Stop.
  var prepare: @Sendable (_ locale: Locale) async throws -> Void
  var transcribe: @Sendable (_ audioURL: URL) async throws -> Transcript
}

extension TranscriptionClient {
  /// The single locale v1 transcribes in. `prepare` callers and `transcribe` implementations
  /// must agree on this so the warm-up installs the same model the batch pass uses.
  static let locale = Locale(identifier: "en-US")
}

extension TranscriptionClient: TestDependencyKey {
  static let previewValue = Self(
    requestAuthorization: { true },
    prepare: { _ in },
    transcribe: { _ in
      try await Task.sleep(for: .seconds(2))
      return Transcript(
        fullText: """
          MSL: Thanks for taking the time today. Before we start, are you comfortable with me \
          recording this conversation? HCP: Yes, that's fine, go ahead. MSL: Great. I wanted to \
          walk you through the phase three efficacy data. HCP: I had questions about the \
          subgroup analysis, actually.
          """
      )
    }
  )

  static let testValue = Self()
}

extension DependencyValues {
  var transcriptionClient: TranscriptionClient {
    get { self[TranscriptionClient.self] }
    set { self[TranscriptionClient.self] = newValue }
  }
}
