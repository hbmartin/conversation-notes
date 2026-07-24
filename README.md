# MSL Interaction Capture

This application (formerly the SpeechRecognition example) is a v1 implementation of an
MSL interaction-capture app built with the Composable Architecture: a Medical Science Liaison
(MSL) records an in-person scientific exchange with a healthcare professional (HCP), the app
transcribes it **on-device**, produces a compliance-safe **prose summary**, and **destroys the
source audio and transcript**. Immediately after, the app runs a **structured voice interview**
with the MSL (TTS asks, STT captures) driven by a Claude agent that must fill a fixed
required-field schema — including mandatory adverse-event and off-label questions — before it
can finish.

## Pipeline & artifact lifecycle

```text
record → transcribe (on-device, SpeechAnalyzer) → transcript into encrypted vault
       → DESTROY AUDIO
       → summarize + extract consent (conversation-service boundary; queues offline)
       → DESTROY TRANSCRIPT
       → SummaryReady → voice interview (retained: audio + transcript + extraction)
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
2. In the app, open **Settings** (gear icon) and paste an Anthropic API key. It is stored in
   the Keychain, device-only.

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
