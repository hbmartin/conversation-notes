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

The sweep now ends with `.launchRecoveryCompleted`, which drains inline. Same guarantees, one
fewer action, and the action name no longer implies work it cannot do. Recovery never produces a
summarizable session, so nothing is lost when the inline drain finds none.

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
   build, and add `MetricKit` (`MXAppLaunchMetric`) if you want field data.

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

## Reproducing the measurements

CPU time per launch (the most reliable single signal — immune to log noise):

```sh
PID=$(xcrun simctl launch booted me.haroldmartin.speechrecognition | awk '{print $2}')
sleep 6 && ps -o cputime=,rss= -p $PID
```

Call graph of the launch:

```sh
PID=$(xcrun simctl launch booted me.haroldmartin.speechrecognition | awk '{print $2}')
sample $PID 3 1 -f /tmp/launch-sample.txt
```

Time to first content, and whether the launch screen still matches the first frame:

```sh
xcrun simctl io booted recordVideo --codec h264 --force /tmp/launch.mp4 &
sleep 3 && xcrun simctl launch booted me.haroldmartin.speechrecognition
sleep 5 && pkill -INT -f "simctl io booted recordVideo"
ffmpeg -i /tmp/launch.mp4 -vf "fps=30,scale=180:-1" -vsync 0 /tmp/frames/f_%04d.png
```

Then read the per-frame mean colour. A large jump between the launch-screen frames and the first
content frame means the colorset has drifted and `LaunchScreenTests` should have caught it.

Seeding a realistic session count:

```sh
CONT=$(xcrun simctl get_app_container booted me.haroldmartin.speechrecognition data)
# write N sessions to "$CONT/Library/Application Support/MSLCapture/sessions.json"
```
