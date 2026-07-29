# MSL Interaction Capture

This application (formerly the SpeechRecognition example) is a v1 implementation of an
MSL interaction-capture app built with the Composable Architecture: a Medical Science Liaison
(MSL) records an in-person scientific exchange with a healthcare professional (HCP), the app
transcribes it **on-device**, produces a compliance-safe **prose summary**, and **destroys the
source audio and transcript**. The MSL can then run a context-aware **structured voice interview**
(TTS asks, STT captures), or start the same guided interview independently from the home screen
without first recording a conversation. The Claude agent must fill a fixed required-field schema
— including mandatory adverse-event and off-label questions — before it can finish.

## Pipeline & artifact lifecycle

```text
conversation → transcribe (on-device, SpeechAnalyzer) → transcript into encrypted vault
             → DESTROY AUDIO
             → summarize + extract consent (conversation-service boundary; queues offline)
             → DESTROY TRANSCRIPT
             → SummaryReady → optional linked voice interview

standalone interview → guided TTS/STT questions with no conversation summary required
                     → retained answer audio + transcript + structured extraction
```

| Artifact | Fate |
|---|---|
| Conversation raw audio | Destroyed immediately after transcription (never waits on network) |
| Conversation transcript | Held encrypted (`NSFileProtectionComplete`) only until summarization succeeds, then destroyed |
| Prose summary + consent utterance | Retained (device-only JSON) |
| Interview audio, transcript, extraction | Retained (`Documents/interviews/<id>/`) |

Crash recovery purges all staged audio at launch and marks in-flight sessions as lost. All
storage is device-only; there is no backend or export in v1.

## Setup

1. Open `SpeechRecognition.xcodeproj` and run the
   `SpeechRecognition` target (iOS 26+; the on-device engine is `SpeechAnalyzer`).
2. Configure an Anthropic API key using one of these development paths:
   * Run `swift Scripts/generate-bundled-key.swift` to securely enter a key and generate the
     git-ignored `Config/BundledKey.private.xcconfig`. Debug builds then use the obfuscated bundled
     key by default.
   * Or open **Settings** (gear icon) in the app and paste a key. An operator-provided key is stored
     in the device Keychain and overrides the bundled key.

## Bundled credentials for TestFlight

The shared **SpeechRecognition-TestFlight** scheme archives with the dedicated `TestFlight` build
configuration. Both Debug and TestFlight read the same reversibly obfuscated payload from
`Config/BundledKey.private.xcconfig`; ordinary Release/App Store builds contain no bundled payload.

Generate or rotate the payload from a terminal at the repository root:

```sh
swift Scripts/generate-bundled-key.swift
```

The prompt does not echo the plaintext key, and the generated private configuration is ignored by
Git. A TestFlight archive fails if the payload is missing or malformed; Debug builds warn and remain
usable with a Keychain key. Obfuscation only prevents casual plaintext discovery and does not make a
credential inside a distributed app secret.

To rotate the shared key, generate a new payload, archive and upload a replacement TestFlight build,
confirm it processes summaries successfully, and only then revoke the old key. Existing TestFlight
builds retain the old embedded credential and stop working as soon as that key is revoked.

Remote features depend only on the provider-neutral `ConversationServiceClient`. The current live
implementation is a temporary BYOK adapter that calls Anthropic directly. It is retained to keep
this prototype runnable, but **must not be treated as the production deployment architecture**.
A production build should replace that adapter with an authenticated gateway that owns provider
credentials, prompt/model versions, rate and cost policy, audit correlation, revocation, and data
retention enforcement. Reducers and persisted domain models do not expose Anthropic request types,
so that replacement does not require feature changes.

## v1 limitations (by design)

* Interrupted recordings (phone call, OS kill, reboot) are lost and the operator is informed —
  there is no resume.
* Transcription requires external power or >30% battery (sustained on-device workload).
* No speaker diarization (the `Transcript.Segment.speaker` field is the seam for a future
  diarizing engine).
* The one-shot summary is not reviewable before the transcript is destroyed, and adverse-event
  capture depends entirely on the operator interview — both accepted risks in the product spec.
* The app flags adverse events but never reports them; reporting is the operator's
  responsibility.
* The gateway transport and its authentication/token exchange are intentionally not implemented in
  this repository yet; only the app-side service boundary and audit metadata seam are present.
