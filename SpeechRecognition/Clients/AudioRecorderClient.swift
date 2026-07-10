import ComposableArchitecture
import Foundation

@DependencyClient
struct AudioRecorderClient: Sendable {
  var currentTime: @Sendable () async -> TimeInterval?
  var requestRecordPermission: @Sendable () async -> Bool = { false }
  /// Starts recording to `url` and resolves when recording finishes: `true` for a clean stop,
  /// `false` when the recorder was interrupted (e.g. an incoming phone call preempted the mic).
  var startRecording: @Sendable (_ url: URL) async throws -> Bool
  var pauseRecording: @Sendable () async -> Void
  var resumeRecording: @Sendable () async -> Void
  var stopRecording: @Sendable () async -> Void
}

extension AudioRecorderClient: TestDependencyKey {
  static var previewValue: Self {
    let isRecording = LockIsolated(false)
    let isPaused = LockIsolated(false)
    let currentTime = LockIsolated(0.0)

    return Self(
      currentTime: { currentTime.value },
      requestRecordPermission: { true },
      startRecording: { _ in
        isRecording.setValue(true)
        while isRecording.value {
          try await Task.sleep(for: .seconds(1))
          if !isPaused.value {
            currentTime.withValue { $0 += 1 }
          }
        }
        return true
      },
      pauseRecording: { isPaused.setValue(true) },
      resumeRecording: { isPaused.setValue(false) },
      stopRecording: {
        isRecording.setValue(false)
        currentTime.setValue(0)
      }
    )
  }

  static let testValue = Self()
}

extension DependencyValues {
  var audioRecorder: AudioRecorderClient {
    get { self[AudioRecorderClient.self] }
    set { self[AudioRecorderClient.self] = newValue }
  }
}
