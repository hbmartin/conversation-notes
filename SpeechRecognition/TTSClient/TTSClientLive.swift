import AVFoundation
import Dependencies

extension TTSClient: DependencyKey {
  static var liveValue: Self {
    let speaker = Speaker()
    return Self(
      speak: { text in try await speaker.speak(text) },
      stop: { await speaker.stop() }
    )
  }
}

private actor Speaker {
  private let synthesizer = AVSpeechSynthesizer()
  private var delegate: Delegate?

  func speak(_ text: String) async throws {
    self.stop()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let delegate = Delegate(utterance: utterance) { completed in
          if completed {
            continuation.resume()
          } else {
            continuation.resume(throwing: CancellationError())
          }
        }
        self.delegate = delegate
        self.synthesizer.delegate = delegate
        self.synthesizer.speak(utterance)
      }
    } onCancel: {
      Task { await self.stop() }
    }
  }

  func stop() {
    self.synthesizer.stopSpeaking(at: .immediate)
    // Delegate callbacks arrive asynchronously on the main queue, so `didCancel` for the
    // stopped utterance can land after a new delegate is installed. Resume the in-flight
    // continuation here instead of trusting callback timing; the late callback then hits a
    // delegate that has already resumed (or one guarding a different utterance) and is a no-op.
    self.delegate?.finishCancelled()
    self.delegate = nil
  }
}

private final class Delegate: NSObject, AVSpeechSynthesizerDelegate, Sendable {
  private let utteranceID: ObjectIdentifier
  private let onDone: @Sendable (Bool) -> Void
  private let hasResumed = LockIsolated(false)

  init(utterance: AVSpeechUtterance, onDone: @escaping @Sendable (Bool) -> Void) {
    self.utteranceID = ObjectIdentifier(utterance)
    self.onDone = onDone
  }

  func finishCancelled() {
    self.resumeOnce(completed: false)
  }

  private func resumeOnce(completed: Bool) {
    let shouldResume = self.hasResumed.withValue { resumed -> Bool in
      guard !resumed else { return false }
      resumed = true
      return true
    }
    if shouldResume {
      self.onDone(completed)
    }
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    guard ObjectIdentifier(utterance) == self.utteranceID else { return }
    self.resumeOnce(completed: true)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    guard ObjectIdentifier(utterance) == self.utteranceID else { return }
    self.resumeOnce(completed: false)
  }
}
