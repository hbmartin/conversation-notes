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

Before distributing a build, create a dedicated credential used only by this prototype. Apply spend
and rate limits at the narrowest provider account or workspace scope available, enable usage alerts,
and keep its revocation separate from personal and production credentials. Every TestFlight tester
can recover the bundled credential, so these operational controls—not obfuscation—bound its risk.

Generate or rotate the payload from a terminal at the repository root:

```sh
swift Scripts/generate-bundled-key.swift
```

The prompt does not echo the plaintext key. The generated private configuration is ignored by Git
and written with owner-only permissions. A TestFlight archive fails if the payload is missing or
malformed; Debug builds warn and remain usable with a Keychain key. Obfuscation only prevents casual
plaintext discovery and does not make a credential inside a distributed app secret.

Run `Scripts/test-bundled-key-format.sh` after changing the payload format. Its golden vectors must
be accepted consistently by the generator, runtime decoder, and build validator.

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

## Feature flags

Conversation capture (the **Record Conversation** home-screen action and everything downstream of
it) is gated by the `CONVERSATION_CAPTURE_ENABLED` build setting. It travels the same path as the
bundled credential — build setting → `Info.plist` (`ConversationCaptureEnabled`) →
`Bundle.main.infoDictionary` → `FeatureFlagsClient` — and is resolved once when `AppFeature.State`
is created.

| Configuration | `CONVERSATION_CAPTURE_ENABLED` | Home screen |
|---|---|---|
| Debug | `YES` | Record Conversation + Start Interview |
| TestFlight | `NO` | Start Interview only |
| Release | `NO` | Start Interview only |

TestFlight and App Store builds therefore ship the guided interview only. The values live in the
app target's per-configuration build settings, not in `Config/BundledKey.xcconfig`, because that
xcconfig is the shared base for both Debug and TestFlight.

The flag fails closed: a missing, unsubstituted, or unrecognized value disables conversation
capture, so a build-setting typo can never ship the feature by accident.

Disabling the flag only removes the *entry point* — it does not amputate the pipeline. Sessions
captured by an earlier build still appear in Recent Activity, still finish transcribing and
summarizing through the queue, and are still swept by launch recovery; otherwise staged audio and
queued transcripts would be stranded on disk.

## App icons

Settings offers four icons — *Woven iris* (the primary icon), *Thread aperture*, *Braided bloom*,
and *Woven iris, inverted* — switched through `AppIconClient` /
`UIApplication.setAlternateIconName(_:)`. The alternates are declared to UIKit by the app target's
`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` build setting, whose names must stay in step with
`AppIconVariant.assetName` (a test asserts this).

All four are drawn, not painted: `AppIconArtwork` holds the geometry as CoreGraphics, which both
the asset-catalog PNGs and the previews in Settings render from, so a choice on that screen cannot
drift from what lands on the home screen. Regenerate the catalog after changing the artwork:

```sh
Scripts/render-app-icons.sh
```

Each icon set is written out at every size iOS asks for rather than as a lone 1024 source. Xcode
downscales a single source for the *primary* icon only, so an alternate declared that way compiles
into the catalog with no icon the home screen can install, and switching to it fails at runtime.

## Launch performance

`docs/launch-performance.md` records what launch actually costs, what was changed, and what is
left. Two checks live outside the test target because they need a built bundle or a running
Simulator:

```sh
Scripts/check-launch-budget.sh       # pre-main work: static ctors, +load, dylibs, embedded frameworks
Scripts/check-launch-continuity.sh   # records a launch and asserts the launch screen paints the aurora
Scripts/measure-launch.sh            # median launch CPU time and its spread — reports, does not gate
```

The first two are deterministic and safe to gate on. The third is not: run-to-run variance is
around 6% on a quiet machine, so read any delta against the spread it prints.

All three measure the Simulator. `LaunchMetricsClient` measures real hardware — it subscribes to
MetricKit at launch and summarises the launch histograms and slow-launch diagnostics into the
unified log:

```sh
log stream --predicate 'subsystem == "me.haroldmartin.speechrecognition"
  AND category == "launch-metrics"' --style compact
```

Nothing is transmitted and nothing is written to disk. MetricKit reports aggregate durations and
call stacks with no access to captured content, and the payloads are summarised into the log and
dropped. That client is the only file that would change if the summaries ever needed to leave the
device.

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
