import ComposableArchitecture
import Speech

extension SpeechClient: DependencyKey {
  static var liveValue: Self {
    let speech = Speech()
    return Self(
      finishTask: {
        await speech.finishTask()
      },
      requestAuthorization: {
        await withCheckedContinuation { continuation in
          SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status)
          }
        }
      },
      startTask: { request, recordingURL in
        let request = UncheckedSendable(request)
        return await speech.startTask(request: request, recordingURL: recordingURL)
      }
    )
  }
}

private actor Speech {
  var audioEngine: AVAudioEngine? = nil
  var recognitionTask: SFSpeechRecognitionTask? = nil
  var recognitionContinuation: AsyncThrowingStream<SpeechRecognitionResult, any Error>.Continuation?
  var recordingFile: AVAudioFile? = nil

  func finishTask() {
    self.audioEngine?.stop()
    self.audioEngine?.inputNode.removeTap(onBus: 0)
    self.recognitionTask?.finish()
    self.recognitionContinuation?.finish()
    self.recordingFile = nil
  }

  func startTask(
    request: UncheckedSendable<SFSpeechAudioBufferRecognitionRequest>,
    recordingURL: URL?
  ) -> AsyncThrowingStream<SpeechRecognitionResult, any Error> {
    let request = request.wrappedValue

    return AsyncThrowingStream { continuation in
      self.recognitionContinuation = continuation
      let audioSession = AVAudioSession.sharedInstance()
      do {
        // One category for the whole interview: TTS playback and mic capture alternate every
        // few seconds, and flapping the session between phases causes audible pops and stalls.
        // Without `.defaultToSpeaker`, `.playAndRecord` routes TTS to the earpiece.
        try audioSession.setCategory(
          .playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
      } catch {
        continuation.finish(throwing: SpeechClient.Failure.couldntConfigureAudioSession)
        return
      }

      self.audioEngine = AVAudioEngine()
      let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
      self.recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
        switch (result, error) {
        case (.some(let result), _):
          continuation.yield(SpeechRecognitionResult(result))
        case (_, .some):
          continuation.finish(throwing: SpeechClient.Failure.taskError)
        case (.none, .none):
          fatalError("It should not be possible to have both a nil result and nil error.")
        }
      }

      guard let inputFormat = self.audioEngine?.inputNode.outputFormat(forBus: 0) else {
        continuation.finish(throwing: SpeechClient.Failure.couldntStartAudioEngine)
        return
      }

      // Only one tap can be installed per bus, so retained interview-answer audio is written
      // from inside the recognition tap.
      if let recordingURL {
        do {
          self.recordingFile = try AVAudioFile(forWriting: recordingURL, settings: inputFormat.settings)
        } catch {
          continuation.finish(throwing: SpeechClient.Failure.couldntWriteRecording)
          return
        }
      }
      let recordingFile = self.recordingFile

      continuation.onTermination = {
        [
          speechRecognizer = UncheckedSendable(speechRecognizer),
          audioEngine = UncheckedSendable(audioEngine),
          recognitionTask = UncheckedSendable(recognitionTask)
        ]
        _ in

        _ = speechRecognizer
        audioEngine.wrappedValue?.stop()
        audioEngine.wrappedValue?.inputNode.removeTap(onBus: 0)
        recognitionTask.wrappedValue?.finish()
      }

      self.audioEngine?.inputNode.installTap(
        onBus: 0,
        bufferSize: 1024,
        format: inputFormat
      ) { buffer, when in
        request.append(buffer)
        try? recordingFile?.write(from: buffer)
      }

      self.audioEngine?.prepare()
      do {
        try self.audioEngine?.start()
      } catch {
        continuation.finish(throwing: SpeechClient.Failure.couldntStartAudioEngine)
        return
      }
    }
  }
}
