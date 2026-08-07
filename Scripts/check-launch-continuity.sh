#!/bin/bash
#
# Does the launch screen actually paint the aurora colour, end to end?
#
# LaunchScreenTests proves two things in isolation: that LaunchBackground.colorset matches the
# mesh, and that Info.plist names it. Neither can prove the system *used* it. An Info.plist
# override in a build configuration, a UILaunchStoryboardName taking precedence, or an asset
# catalog that failed to compile the colorset would all leave those tests green while the white
# flash came back. Only looking at the screen catches that, so this records a launch and reads
# the pixels.
#
# The expected colour is parsed from the colorset itself, so this script cannot drift from the
# asset — and LaunchScreenTests keeps the asset from drifting from the mesh.
#
# Usage:
#   Scripts/check-launch-continuity.sh
#   Scripts/check-launch-continuity.sh --keep    # leave the recording and frame data behind
#
# Requires ffmpeg, and the app installed on the booted Simulator.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
colorset="$repo_root/SpeechRecognition/Assets.xcassets/LaunchBackground.colorset/Contents.json"
bundle_id="me.haroldmartin.speechrecognition"
keep=0

while (( $# > 0 )); do
  case "$1" in
    --keep) keep=1; shift ;;
    -b) bundle_id="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

command -v ffmpeg > /dev/null || { echo "error: ffmpeg not found (brew install ffmpeg)" >&2; exit 2; }
[[ -f "$colorset" ]] || { echo "error: no colorset at $colorset" >&2; exit 2; }
if ! xcrun simctl get_app_container booted "$bundle_id" > /dev/null 2>&1; then
  echo "error: $bundle_id is not installed on the booted Simulator." >&2
  exit 2
fi

work_dir="$(mktemp -d)"
previous_appearance="$(xcrun simctl ui booted appearance 2>/dev/null || echo light)"
cleanup() {
  xcrun simctl ui booted appearance "$previous_appearance" > /dev/null 2>&1 || true
  if (( keep )); then
    echo "Recording kept at $work_dir"
  else
    rm -rf "$work_dir"
  fi
}
trap cleanup EXIT

# The colorset carries a light and a dark appearance; compare against the one being rendered.
xcrun simctl ui booted appearance light > /dev/null
xcrun simctl terminate booted "$bundle_id" > /dev/null 2>&1 || true
sleep 1

echo "Recording a launch…"
xcrun simctl io booted recordVideo --codec h264 --force "$work_dir/launch.mp4" &
recorder=$!
sleep 3
xcrun simctl launch booted "$bundle_id" > /dev/null
sleep 5
kill -INT "$recorder" 2>/dev/null || true
wait "$recorder" 2>/dev/null || true

# One RGB triple per frame, from the middle of the screen: the status bar and home indicator sit
# outside this crop and would otherwise drag every mean toward their own colours.
ffmpeg -v error -i "$work_dir/launch.mp4" \
  -vf "fps=30,crop=iw*0.8:ih*0.5:iw*0.1:ih*0.25,scale=1:1" \
  -f rawvideo -pix_fmt rgb24 "$work_dir/frames.rgb"

python3 - "$colorset" "$work_dir/frames.rgb" <<'PY'
import json
import sys

colorset_path, frames_path = sys.argv[1], sys.argv[2]

# A frame is "the launch screen" if it is within this distance of the expected colour. The gap
# between the launch screen and the first content frame is roughly 35, so this separates them
# with room to spare while tolerating h264 quantisation and the scaling above.
MATCH_TOLERANCE = 14
# All three channels this high can only be the system's default white launch screen; the aurora
# never gets there, its red channel sits near 200 even at its palest.
WHITE_FLOOR = 245
# How far a frame must sit from the pre-launch home screen to count as the launch having begun.
LAUNCH_THRESHOLD = 25
# How close to the final content a frame must be to count as launch having finished.
SETTLED_TOLERANCE = 12


def light_components(path):
    catalog = json.load(open(path))
    for entry in catalog["colors"]:
        appearances = entry.get("appearances", [])
        if any(a.get("value") == "dark" for a in appearances):
            continue
        components = entry["color"]["components"]
        return tuple(round(float(components[c]) * 255) for c in ("red", "green", "blue"))
    raise SystemExit("error: colorset has no light appearance")


def distance(a, b):
    return max(abs(x - y) for x, y in zip(a, b))


expected = light_components(colorset_path)
raw = open(frames_path, "rb").read()
frames = [tuple(raw[i:i + 3]) for i in range(0, len(raw) - 2, 3)]
if len(frames) < 30:
    raise SystemExit(f"error: only {len(frames)} frames recorded; the launch was not captured")

home = frames[0]
content = frames[-1]

start = next((i for i, f in enumerate(frames) if distance(f, home) > LAUNCH_THRESHOLD), None)
if start is None:
    raise SystemExit("error: the screen never changed; the app did not launch")
end = next(
    (i for i in range(start, len(frames)) if distance(frames[i], content) < SETTLED_TOLERANCE),
    len(frames),
)

window = frames[start:end]
print(f"\n  expected launch colour   rgb{expected}")
print(f"  home screen              rgb{home}")
print(f"  settled content          rgb{content}")
print(f"  launch window            frames {start}–{end} ({len(window)} frames, "
      f"{len(window) / 30:.2f}s)")

white = [f for f in window if min(f) >= WHITE_FLOOR]
matched = [f for f in window if distance(f, expected) <= MATCH_TOLERANCE]
closest = min(window, key=lambda f: distance(f, expected)) if window else None

failures = []
if white:
    failures.append(
        f"{len(white)} frame(s) during launch are effectively white (e.g. rgb{white[0]}). "
        "UILaunchScreen is falling back to the system default — check that Info.plist's "
        "UIColorName survives into the built bundle and that the colorset compiled."
    )
if not matched:
    failures.append(
        f"no frame during launch matched rgb{expected} within {MATCH_TOLERANCE}; "
        f"closest was rgb{closest} (off by {distance(closest, expected)}). "
        "The launch screen is painting something other than the aurora."
    )

if failures:
    print()
    for failure in failures:
        print(f"  ✗ {failure}")
    print()
    raise SystemExit(1)

print(f"  ✓ {len(matched)} launch frames match the colorset, none are white\n")
PY
