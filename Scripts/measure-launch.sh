#!/bin/bash
#
# Launch CPU time on the booted Simulator: median of N runs, reported alongside the spread.
#
# This reports, it does not gate. docs/launch-performance.md records why: launch is ~1.8
# CPU-seconds of framework startup, app-owned code is ~5% of it, and run-to-run variance on a
# shared machine is wide enough that a single pair of measurements will happily "prove" a
# regression that is not there. The spread printed at the bottom is the point — read any delta
# against it before believing it.
#
# CPU time rather than wall clock, because it is immune to how busy the host is and to whatever
# the console happens to be logging.
#
# Usage:
#   Scripts/measure-launch.sh                # 7 runs, first discarded
#   Scripts/measure-launch.sh -n 15
#   Scripts/measure-launch.sh -s 8           # settle 8s before sampling
#
# Requires the app already installed on the booted Simulator:
#   xcodebuild -scheme SpeechRecognition -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
#   xcrun simctl install booted <path to .app>

set -euo pipefail

bundle_id="me.haroldmartin.speechrecognition"
runs=7
settle=6

while (( $# > 0 )); do
  case "$1" in
    -n) runs="$2"; shift 2 ;;
    -s) settle="$2"; shift 2 ;;
    -b) bundle_id="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if ! xcrun simctl get_app_container booted "$bundle_id" > /dev/null 2>&1; then
  echo "error: $bundle_id is not installed on the booted Simulator." >&2
  echo "       Build it and run: xcrun simctl install booted <path to .app>" >&2
  exit 2
fi

# ps prints cpu time as [[hh:]mm:]ss.ss.
to_seconds() {
  awk -F: '{
    s = $NF
    if (NF >= 2) s += $(NF - 1) * 60
    if (NF >= 3) s += $(NF - 2) * 3600
    printf "%.2f", s
  }' <<< "$1"
}

samples=()
echo
echo "Measuring $bundle_id — $runs runs, ${settle}s settle, first discarded as cold"
for (( run = 1; run <= runs; run++ )); do
  xcrun simctl terminate booted "$bundle_id" > /dev/null 2>&1 || true
  sleep 1
  pid="$(xcrun simctl launch booted "$bundle_id" | awk '{print $2}')"
  sleep "$settle"
  raw="$(ps -o cputime= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [[ -z "$raw" ]]; then
    echo "  run $run: process exited before sampling — discarded"
    continue
  fi
  seconds="$(to_seconds "$raw")"
  if (( run == 1 )); then
    printf '  run %-2s %6ss  (cold, discarded)\n' "$run" "$seconds"
  else
    printf '  run %-2s %6ss\n' "$run" "$seconds"
    samples+=("$seconds")
  fi
done
xcrun simctl terminate booted "$bundle_id" > /dev/null 2>&1 || true

if (( ${#samples[@]} < 2 )); then
  echo "error: not enough successful runs to report" >&2
  exit 1
fi

printf '%s\n' "${samples[@]}" | sort -n | awk '
  { v[NR] = $1 }
  END {
    median = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
    spread = v[NR] - v[1]
    printf "\n  median   %.2fs   (n=%d)\n", median, NR
    printf "  range    %.2fs – %.2fs\n", v[1], v[NR]
    printf "  spread   %.2fs  (%.0f%% of median)\n\n", spread, 100 * spread / median
    printf "  A change smaller than the spread is not a result. Re-measure both builds\n"
    printf "  interleaved before drawing a conclusion.\n\n"
  }
'
