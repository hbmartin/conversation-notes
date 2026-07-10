import AVFoundation
import Dependencies

extension AudioRecorderClient: DependencyKey {
  static var liveValue: Self {
    let audioRecorder = AudioRecorder()
    return Self(
      currentTime: { await audioRecorder.currentTime },
      requestRecordPermission: { await AudioRecorder.requestPermission() },
      startRecording: { url in try await audioRecorder.start(url: url) },
      pauseRecording: { await audioRecorder.pause() },
      resumeRecording: { await audioRecorder.resume() },
      stopRecording: { await audioRecorder.stop() }
    )
  }
}

private actor AudioRecorder {
  var delegate: Delegate?
  var recorder: AVAudioRecorder?

  var currentTime: TimeInterval? {
    guard let recorder = self.recorder else { return nil }
    return recorder.currentTime
  }

  static func requestPermission() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }

  func pause() {
    self.recorder?.pause()
  }

  func resume() {
    self.recorder?.record()
  }

  func stop() {
    self.recorder?.stop()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func start(url: URL) async throws -> Bool {
    self.stop()

    let stream = AsyncThrowingStream<Bool, any Error> { continuation in
      do {
        self.delegate = Delegate(
          didFinishRecording: { flag in
            continuation.yield(flag)
            continuation.finish()
          },
          encodeErrorDidOccur: { error in
            continuation.finish(throwing: error)
          }
        )
        let recorder = try AVAudioRecorder(
          url: url,
          settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
          ])
        self.recorder = recorder
        recorder.delegate = self.delegate

        continuation.onTermination = { [recorder = UncheckedSendable(recorder)] _ in
          recorder.wrappedValue.stop()
        }

        // `.playAndRecord`+`.spokenAudio` is shared with the interview flow (TTS + mic) and,
        // together with the `audio` background mode, keeps recording alive under screen lock.
        try AVAudioSession.sharedInstance().setCategory(
          .playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
        try AVAudioSession.sharedInstance().setActive(true)
        self.recorder?.record()
      } catch {
        continuation.finish(throwing: error)
      }
    }

    for try await didFinish in stream {
      return didFinish
    }
    throw CancellationError()
  }
}

private final class Delegate: NSObject, AVAudioRecorderDelegate, Sendable {
  let didFinishRecording: @Sendable (Bool) -> Void
  let encodeErrorDidOccur: @Sendable ((any Error)?) -> Void

  init(
    didFinishRecording: @escaping @Sendable (Bool) -> Void,
    encodeErrorDidOccur: @escaping @Sendable ((any Error)?) -> Void
  ) {
    self.didFinishRecording = didFinishRecording
    self.encodeErrorDidOccur = encodeErrorDidOccur
  }

  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    self.didFinishRecording(flag)
  }

  func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
    self.encodeErrorDidOccur(error)
  }
}
