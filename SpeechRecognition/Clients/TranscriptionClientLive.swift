import AVFoundation
import Dependencies
import Speech

enum TranscriptionError: LocalizedError {
  case unsupportedLocale(Locale)
  case assetInstallationFailed(any Error)

  var errorDescription: String? {
    switch self {
    case .unsupportedLocale(let locale):
      return "On-device transcription does not support the “\(locale.identifier)” locale."
    case .assetInstallationFailed(let error):
      return "The on-device speech model could not be installed: \(error.localizedDescription)"
    }
  }
}

/// Live implementation on the iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` stack: fully
/// on-device, file-based, no network at transcription time. Diarization is not provided by
/// this engine in v1.
extension TranscriptionClient: DependencyKey {
  static var liveValue: Self {
    Self(
      requestAuthorization: {
        // SpeechAnalyzer is on-device and app-initiated; it does not require the
        // SFSpeechRecognizer authorization that the live-mic interview STT uses.
        true
      },
      prepare: {
        _ = try await ensureModelAssets(for: TranscriptionClient.locale)
      },
      transcribe: { audioURL in
        // Without the model assets installed, the analyzer cannot determine its supported
        // sampling rates and fails with a misleading "Audio format is not supported" error —
        // so assets are (re)ensured here rather than trusting the warm-up `prepare` call.
        let locale = try await ensureModelAssets(for: TranscriptionClient.locale)
        let transcriber = SpeechTranscriber(
          locale: locale,
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

/// Ensures the on-device speech model for `locale` is installed, returning the canonical
/// supported-locale instance to construct the transcriber with (asset lookup is sensitive to
/// the exact locale identifier form).
private func ensureModelAssets(for locale: Locale) async throws -> Locale {
  let supported = await SpeechTranscriber.supportedLocales
  guard
    let match = supported.first(where: {
      $0.identifier(.bcp47) == locale.identifier(.bcp47)
    })
      ?? supported.first(where: {
        $0.language.languageCode == locale.language.languageCode
      })
  else {
    throw TranscriptionError.unsupportedLocale(locale)
  }

  let installed = await SpeechTranscriber.installedLocales
  guard !installed.contains(where: { $0.identifier(.bcp47) == match.identifier(.bcp47) })
  else { return match }

  let transcriber = SpeechTranscriber(
    locale: match,
    transcriptionOptions: [],
    reportingOptions: [],
    attributeOptions: []
  )
  do {
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await request.downloadAndInstall()
    }
  } catch {
    throw TranscriptionError.assetInstallationFailed(error)
  }
  return match
}
