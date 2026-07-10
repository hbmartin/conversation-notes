import AVFoundation
import Dependencies
import Speech

/// Live implementation on the iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` stack: fully
/// on-device, file-based, no network. Diarization is not provided by this engine in v1.
extension TranscriptionClient: DependencyKey {
  static var liveValue: Self {
    Self(
      requestAuthorization: {
        // SpeechAnalyzer is on-device and app-initiated; it does not require the
        // SFSpeechRecognizer authorization that the live-mic interview STT uses.
        true
      },
      prepare: { locale in
        let transcriber = SpeechTranscriber(
          locale: locale,
          transcriptionOptions: [],
          reportingOptions: [],
          attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(
          supporting: [transcriber]
        ) {
          try await request.downloadAndInstall()
        }
      },
      transcribe: { audioURL in
        let transcriber = SpeechTranscriber(
          locale: Locale(identifier: "en-US"),
          transcriptionOptions: [],
          reportingOptions: [],
          attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        async let collectedText: AttributedString = transcriber.results.reduce(
          into: AttributedString()
        ) { text, result in
          text += result.text
        }

        let audioFile = try AVAudioFile(forReading: audioURL)
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
          try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
          await analyzer.cancelAndFinishNow()
        }

        let text = try await collectedText
        return Transcript(fullText: String(text.characters))
      }
    )
  }
}
