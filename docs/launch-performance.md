# Launch performance

Investigation of "the app feels slow to launch," 2026-08-04. Records what was measured, what
changed, and what is left to do — so the next person does not re-derive the same numbers.

## Summary

Launch costs **~1.8 CPU-seconds**, and that number does not move when you change the things you
would expect to matter. App-owned code accounts for roughly 5% of it. What made launch *feel* slow
was a plain white launch screen followed by a fully-rendered aurora screen: a flash, not a wait.

The flash is fixed. The wait is almost entirely framework startup, and reducing it further needs
on-device measurement before any code changes — see [Followups](#followups).

## What was measured

iPhone 17 Pro Simulator, iOS 26.3, Xcode 26.3 (17C529). Four independent methods: system log
timelines, process CPU time, `sample` call graphs, and 30fps screen recordings.

### Launch cost is flat

CPU-seconds consumed 6s after launch, three runs each:

| Variant | CPU time |
| --- | --- |
| Debug, 0 sessions | 1.81 / 1.83 / 1.80 |
| Debug, 200 sessions | 1.87 / 1.81 / 1.83 |
| Debug, 1000 sessions | 1.84 / 1.89 / 1.82 |
| Debug **without** `._printChanges()`, 1000 sessions | 1.93 / 2.23 / 1.79 |
| Release, 1000 sessions | 1.90 / 1.77 / 1.79 |

Session count does not matter. `_printChanges` does not matter. Release vs Debug does not matter.
The `_printChanges` variant was built from a scratch copy of the tree with the modifier deleted;
it is not a checked-in configuration.

This matters mostly as a **negative result**: the console output at launch looks eventful, but it
is not evidence of cost. Do not optimise against it.

### Where the time goes

`sample` on the launching process, 421 samples on the main thread under `start`:

| Frame | Samples | Share |
| --- | --- | --- |
| `-[UIApplication _accessibilityInit]` → `NSBundle loadAndReturnError:` → `dlopen` | 178 | 42% |
| first `CA::Transaction::commit` → `_UIHostingView.layoutSubviews` | 72 | 17% |
| `-[UIApplication _immediatelyUpdateSerializableKeyCommands]` (responder-chain walk) | 57 | 14% |
| `SpeechRecognitionApp.store` one-time init | 22 | 5% |
| └ of which `@Shared(.sessions)` load + JSON decode of **1000** sessions | 13 | 3% |

Plus ~137 samples spread across threads in `swift_conformsToProtocolMaybeInstantiateSuperclasses`
and `swift_getTypeByMangledName` — generic-metadata lookups from the SwiftUI + TCA type graph.

Nearly half of main-thread startup is UIKit `dlopen`-ing accessibility bundles. That is heavily
Simulator-flavoured; see [Followups](#followups).

### What the user actually sees

From the screen recording, measuring from the end of SpringBoard's open animation:

- **before:** ~470ms of pure white (`#FFFFFF`), then the aurora screen appears — a hard cut
- **after:** the same interval, but painted in the aurora's own tone, then content fades in

The interval is unchanged. The discontinuity is gone.

## What changed

### Launch screen colour (the fix)

`Info.plist` had `UILaunchScreen` as an empty `<dict/>`, which means white. It now names a colour
asset:

```xml
<key>UILaunchScreen</key>
<dict>
    <key>UIColorName</key>
    <string>LaunchBackground</string>
</dict>
```

`LaunchBackground.colorset` holds light and dark values derived from the aurora mesh: the flat
average of the nine mesh stops, shifted by half of `AuroraBackground`'s diagonal overlay opacity
(the overlay ramps from `.clear`, so half is its mean contribution).

The launch screen is drawn by the system before any app code runs, so nothing at runtime can keep
the asset in sync with the mesh. `AppTheme` therefore holds the palette as raw sRGB components
(`AppTheme.Stop`) and derives `launchBackgroundLight` / `launchBackgroundDark` from them;
`LaunchScreenTests` fails if the compiled asset drifts from that derivation, or if the plist stops
pointing at it. **Edit the mesh and the test tells you to re-export the colorset** — the current
values are:

| | red | green | blue |
| --- | --- | --- | --- |
| light | 0.888778 | 0.920122 | 0.997978 |
| dark | 0.078711 | 0.091911 | 0.219022 |

### `launchRecoveryCompleted` replaces a no-op `drainQueue`

The crash-recovery sweep used to end with `send(.drainQueue)`. At launch that was always a no-op:
`isConnected` starts `false` and `NWPathMonitor` does not report for tens of milliseconds, so the
drain could not do anything. `connectivityChanged` then sent a second `drainQueue` that did the
real work — the `drainQueue → connectivityChanged(true) → drainQueue` sequence in the logs.

The sweep now ends with `.launchRecoveryCompleted`, which drains inline. Recovery never produces a
summarizable session, so nothing is lost when the inline drain finds none.

This does not remove an action — launch still takes four, and `LaunchWorkTests` pins them. What it
removes is a *lie*: the action that runs after recovery no longer claims to drain a queue it
cannot reach. The redundant dispatch is gone; the count is the same because `connectivityChanged`
still sends the one `drainQueue` that does the work.

### `.finish()` is documented, not changed

`await store.send(.onLaunch).finish()` never returns, because `onLaunch` merges the connectivity
observation and that stream runs for the life of the app. That is correct: awaiting it ties the
monitor's lifetime to the root view's. It now says so in a comment.

## Deliberately not changed

`interviewArtifacts.storedIDs()` (`AppFeature.swift`) is synchronous `FileManager` I/O running on
the main actor inside the reducer. Moving it into the effect would be the obvious fix and it is
**wrong**: the orphan set must be snapshotted in the same synchronous turn as the session-state
fixup, or an interview started while the sweep is in flight can have its artifacts destroyed.
`interviewStartedDuringRecoveryKeepsItsArtifacts` pins this.

It also does not show up in any measurement — 150 seeded directories were invisible in both CPU
time and the sample. A safe redesign is sketched in the followups below; do not attempt the naive
version.

## Followups

1. **Measure on device before touching anything else.** These numbers are Simulator numbers and
   the profile is distorted: `dyld_sim` instead of the shared cache, and an accessibility bundle
   `dlopen` storm that dominates the main thread. On hardware, expect page-in and first-run Metal
   shader compilation (MeshGradient, Liquid Glass, `.regularMaterial`) to matter more and
   `_accessibilityInit` to matter less. Use the Instruments **App Launch** template on a release
   build. MetricKit is now wired up (see [Field measurement](#field-measurement)) and will answer
   this on its own once a TestFlight build has been in someone's hands for a day.

2. **Re-check the first-frame render cost on device.** 17% of main-thread startup was
   `_UIHostingView.layoutSubviews` on the first CA commit — the aurora mesh, the glass container,
   and the materials. If that holds on hardware, the lever is rendering something cheaper for the
   first frame and upgrading after, not micro-optimising the reducer.

3. **Check whether `_immediatelyUpdateSerializableKeyCommands` is real on device.** 14% of
   main-thread startup went to UIKit walking the responder chain building key commands. It may be
   a Simulator artifact (hardware-keyboard support). If it reproduces on device it is worth a
   radar rather than a workaround.

4. **If `storedIDs()` ever does show up**, the safe redesign is to enumerate with
   `.creationDateKey` and ignore any directory created at or after the launch timestamp — a
   directory belonging to a live interview is by definition created in the current process, and an
   orphan by definition is not. That preserves the invariant without needing the synchronous
   snapshot, and lets the listing move into the effect. It needs a cutoff `Date` threaded from
   `@Dependency(\.date.now)` so tests stay deterministic.

5. **`sessions.json` has no pruning.** The decode is linear in session count and runs synchronously
   in `AppFeature.State.init()` on the main thread, before the first frame. It measured at 3% with
   1000 sessions, so it is not urgent, but there is no upper bound today. Retention policy or
   pagination would cap it.

## Automation

The measurements above were done by hand. What is worth automating is not all of them — a CI
Simulator stopwatch has enough variance to invent the very regression it is looking for, which is
how the 200-session result above went wrong. So the split is: **gate on things that can be
counted, report on things that must be timed.**

### Gate on every change

| What | Where | Catches |
| --- | --- | --- |
| The exact launch action sequence | `LaunchWorkTests` | new launch-time work, redundant round trips |
| `State.init` reads only the feature flag | `LaunchWorkTests` | disk or network added before the first frame |
| `Session`'s persisted field set | `LaunchWorkTests` | a fat field multiplied by session count at launch |
| Launch colour matches the mesh; plist names it | `LaunchScreenTests` | colorset drift when the palette is edited |
| Static initializers, non-lazy classes, dylibs, embedded frameworks | `Scripts/check-launch-budget.sh` | pre-main work: `+load`, C++ static ctors, a new dynamic framework |
| The launch screen actually paints the aurora | `Scripts/check-launch-continuity.sh` | the white flash returning for a reason the unit tests cannot see |
| Quantile reporting over MetricKit histograms | `LaunchMetricsTests` | field numbers being misread — empty histograms, tail buckets, boundaries |

None of these time anything, so none of them flake. `check-launch-budget.sh` must run against a
Release build — Debug links a stub through `SpeechRecognition.debug.dylib` and every count would
read a meaningless zero, which the script refuses rather than reporting.

`check-launch-continuity.sh` is the end-to-end complement to `LaunchScreenTests`: those tests
prove the asset matches the mesh and that `Info.plist` names it, but neither can prove the *system
used it*. A plist override in a build configuration or a colorset that failed to compile would
leave them green. This one records a launch and reads the pixels, with the expected colour parsed
out of the colorset so the check cannot drift from the asset.

Both scripts have been verified against a deliberately broken build — removing `UIColorName`
produces `26 frame(s) during launch are effectively white`, naming the cause.

### Report, do not gate

```sh
Scripts/measure-launch.sh -n 15
```

Median launch CPU time over N runs, printed with the spread. The spread is the point: on this
machine it runs ~6% of the median, so a delta smaller than that is not a result. Run it nightly
and chart it; do not fail a build on it.

Call graph, for when the number moves and you need to know why:

```sh
PID=$(xcrun simctl launch booted me.haroldmartin.speechrecognition | awk '{print $2}')
sample $PID 3 1 -f /tmp/launch-sample.txt
```

Seeding a realistic session count:

```sh
CONT=$(xcrun simctl get_app_container booted me.haroldmartin.speechrecognition data)
# write N sessions to "$CONT/Library/Application Support/MSLCapture/sessions.json"
```

### Field measurement

Everything above measures a Simulator. `LaunchMetricsClient` measures real hardware: `onLaunch`
subscribes to MetricKit, and once a day the system hands back histograms describing runs that
already finished. This is the only instrument that can answer followup 1, because the distortion
it exists to correct for — `dyld_sim`, the accessibility `dlopen` storm — is invisible from inside
the Simulator.

Four histograms are logged per payload:

| Histogram | What it means |
| --- | --- |
| `timeToFirstDraw` | process start to the first CA commit finishing — the headline number |
| `optimizedTimeToFirstDraw` | the same, for launches the system pre-warmed; kept separate so it cannot flatter the headline |
| `extendedLaunch` | past the first frame, through to interactive |
| `resume` | returning from the background |

Read them with the app running on a connected device:

```sh
log stream --predicate 'subsystem == "me.haroldmartin.speechrecognition"
  AND category == "launch-metrics"' --style compact
```

```
launch 2026-08-06 v1.0 timeToFirstDraw: n=214  p50 700–800ms  p90 1400–1600ms  max <2500ms
```

Quantiles are reported as the bucket they fall in, never as a point. MetricKit's launch buckets
run hundreds of milliseconds wide, so `p50 = 843ms` would be precision that does not exist.

The subscriber also logs `MXAppLaunchDiagnostic` and `MXHangDiagnostic` at `error` level. Those
are the ones worth watching: the system raises a launch diagnostic when a launch crossed *its own*
slow threshold, which is the closest thing to a field alarm for the complaint that started this
document. The call stack that comes with it is in Xcode Organizer rather than the log, where it is
readable.

**Nothing is transmitted and nothing is written to disk.** Payloads are summarised into the
unified log and dropped. MetricKit reports aggregate durations and call stacks — it has no access
to anything the operator recorded — but the client is deliberately the only place that would have
to change if these summaries ever needed to go somewhere, so that decision stays in one file.

Payloads arrive at most once a day, which makes the path awkward to exercise. Xcode's
**Debug → Simulate MetricKit Payloads** delivers a synthetic one immediately while the app is
running from Xcode. Note that the subscription itself measured free: interleaved before/after
runs put the median at 1.79s and 1.80s, inside a 0.05s run-to-run spread.

### Not built yet

- **`OSSignposter` intervals** around `State.init`, the sessions decode, and the recovery sweep,
  exported in CI with `xctrace export --xpath` over the `os-signpost` table. This turns the
  hand-rolled `sample` breakdown above into a repeatable artifact that attributes a regression to
  a phase instead of reporting a larger total.
- **`mxSignpost` instead of plain `os_signpost`** for those same probes, so the intervals come
  back from TestFlight builds in the MetricKit payloads already being received here — one set of
  probes, local traces and field data both. `MXMetricManager.makeLogHandle(category:)` is the
  entry point, and `LaunchMetricsSubscriber` already handles the payloads they would arrive in.

`XCTApplicationLaunchMetric` is the official answer for a local before/after and is genuinely
useful as one, but it needs a UI test target this project does not have, and its baselines are
stored per device configuration, which is painful to keep green across CI runner images.
