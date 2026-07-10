import ComposableArchitecture
import Foundation
import Speech

/// Live-streaming speech-to-text over the microphone, used for the operator's spoken interview
/// answers. Pass a `recordingURL` to also capture the raw mic audio to disk (interview answers
/// are retained artifacts, unlike conversation audio).
@DependencyClient
struct SpeechClient {
  var finishTask: @Sendable () async -> Void
  var requestAuthorization: @Sendable () async -> SFSpeechRecognizerAuthorizationStatus = {
    .notDetermined
  }
  var startTask:
    @Sendable (
      _ request: SFSpeechAudioBufferRecognitionRequest,
      _ recordingURL: URL?
    ) async -> AsyncThrowingStream<
      SpeechRecognitionResult, Error
    > = { _, _ in .finished() }

  enum Failure: Error, Equatable {
    case taskError
    case couldntStartAudioEngine
    case couldntConfigureAudioSession
    case couldntWriteRecording
  }
}

extension SpeechClient: TestDependencyKey {
  static var previewValue: Self {
    let isRecording = LockIsolated(false)

    return Self(
      finishTask: { isRecording.setValue(false) },
      requestAuthorization: { .authorized },
      startTask: { _, _ in
        AsyncThrowingStream { continuation in
          Task {
            isRecording.setValue(true)
            var finalText = """
              Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor \
              incididunt ut labore et dolore magna aliqua.
              """
            var text = ""
            while isRecording.value {
              let word = finalText.prefix { $0 != " " }
              try await Task.sleep(for: .milliseconds(word.count * 50 + .random(in: 0...200)))
              finalText.removeFirst(word.count)
              if finalText.first == " " {
                finalText.removeFirst()
              }
              text += word + " "
              continuation.yield(
                SpeechRecognitionResult(
                  bestTranscription: Transcription(
                    formattedString: text,
                    segments: []
                  ),
                  isFinal: false,
                  transcriptions: []
                )
              )
              if finalText.isEmpty { break }
            }
          }
        }
      }
    )
  }

  static let testValue = Self()
}

extension DependencyValues {
  var speechClient: SpeechClient {
    get { self[SpeechClient.self] }
    set { self[SpeechClient.self] = newValue }
  }
}
