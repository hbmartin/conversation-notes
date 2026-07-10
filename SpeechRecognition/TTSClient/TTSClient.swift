import ComposableArchitecture
import Foundation

/// Text-to-speech for the interview agent's questions. `speak` returns when the utterance has
/// finished (or was stopped). Deliberately does not touch the shared `AVAudioSession` — the
/// interview flow configures a single `.playAndRecord` session up front and never flaps it
/// between phases.
@DependencyClient
struct TTSClient: Sendable {
  var speak: @Sendable (_ text: String) async throws -> Void
  var stop: @Sendable () async -> Void
}

extension TTSClient: TestDependencyKey {
  static let previewValue = Self(
    speak: { text in
      try await Task.sleep(for: .seconds(max(0.8, Double(text.count) * 0.03)))
    },
    stop: {}
  )

  static let testValue = Self()
}

extension DependencyValues {
  var ttsClient: TTSClient {
    get { self[TTSClient.self] }
    set { self[TTSClient.self] = newValue }
  }
}
