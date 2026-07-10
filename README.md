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
       → summarize + extract consent (Anthropic API; queues offline) → DESTROY TRANSCRIPT
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
   the Keychain, device-only. Summarization and the interview call
   `POST https://api.anthropic.com/v1/messages` (`claude-opus-4-8`) directly.

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
