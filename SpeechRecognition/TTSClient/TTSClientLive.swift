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
        let delegate = Delegate { completed in
          if completed {
            continuation.resume()
          } else {
            continuation.resume(throwing: CancellationError())
          }
        }
        self.delegate = delegate
        self.synthesizer.delegate = delegate
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        self.synthesizer.speak(utterance)
      }
    } onCancel: {
      Task { await self.stop() }
    }
  }

  func stop() {
    // Triggers the delegate's `didCancel`, which resumes any in-flight continuation.
    self.synthesizer.stopSpeaking(at: .immediate)
  }
}

private final class Delegate: NSObject, AVSpeechSynthesizerDelegate, Sendable {
  private let onDone: @Sendable (Bool) -> Void
  private let hasResumed = LockIsolated(false)

  init(onDone: @escaping @Sendable (Bool) -> Void) {
    self.onDone = onDone
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
    self.resumeOnce(completed: true)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    self.resumeOnce(completed: false)
  }
}
