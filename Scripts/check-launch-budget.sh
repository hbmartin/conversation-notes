#!/bin/bash
#
# Static launch budget.
#
# Everything counted here is work the dynamic linker and the Objective-C runtime do before main()
# — before any app code, and before anything is on screen. Unlike a stopwatch it has no variance,
# so it can gate a pull request: the numbers either changed or they did not.
#
# See docs/launch-performance.md for why the timing-based alternatives are reporting tools rather
# than gates.
#
# Usage:
#   Scripts/check-launch-budget.sh                 # builds Release into a temp derived data dir
#   Scripts/check-launch-budget.sh --app path.app  # inspects an already-built .app
#
# Raising a budget is a deliberate act. Do it in the same commit as the change that needs it, and
# say in the message what the launch cost buys.

set -euo pipefail

# --- budgets -----------------------------------------------------------------------------------

# C++ static constructors and anything else in __mod_init_func. Every one of these runs serially
# before main(). The app has none today and there is no good reason for it to gain one.
readonly MAX_STATIC_INITIALIZERS=0

# Objective-C classes with a +load method, which the runtime must realize eagerly rather than
# lazily on first use. One comes in from the SDK; app code should not add more.
readonly MAX_NON_LAZY_CLASSES=1

# Every linked dylib is a load command dyld resolves at launch. The Swift runtime libraries
# dominate this list and are unavoidable; new *framework* imports are the ones to notice.
#
# Raised 39 → 41 for MetricKit.framework and libswiftMetricKit.dylib, which LaunchMetricsClient
# needs. Both come out of the shared cache, and an interleaved before/after put launch at 1.79s
# against 1.80s — inside a 0.05s spread. That buys the only measurements this project has from
# real hardware; see the Field measurement section of docs/launch-performance.md.
readonly MAX_LINKED_DYLIBS=41

# Embedded dynamic frameworks are dlopen'd from the bundle at launch, off the shared cache, and
# are the single most expensive thing on this list. The app ships zero.
readonly MAX_EMBEDDED_FRAMEWORKS=0

# --- locate the binary -------------------------------------------------------------------------

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path=""

while (( $# > 0 )); do
  case "$1" in
    --app)
      app_path="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$app_path" ]]; then
  build_dir="$(mktemp -d)"
  trap 'rm -rf "$build_dir"' EXIT
  echo "Building Release for static analysis…"
  xcodebuild \
    -project "$repo_root/SpeechRecognition.xcodeproj" \
    -scheme SpeechRecognition \
    -configuration Release \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$build_dir" \
    -skipMacroValidation \
    build > "$build_dir/build.log" 2>&1 || {
      echo "error: build failed. Log: $build_dir/build.log" >&2
      tail -20 "$build_dir/build.log" >&2
      trap - EXIT
      exit 1
    }
  app_path="$build_dir/Build/Products/Release-iphonesimulator/SpeechRecognition.app"
fi

if [[ ! -d "$app_path" ]]; then
  echo "error: no app bundle at $app_path" >&2
  exit 2
fi

binary="$app_path/SpeechRecognition"
if [[ ! -f "$binary" ]]; then
  echo "error: no executable at $binary" >&2
  exit 2
fi

# Debug builds link a thin stub against SpeechRecognition.debug.dylib so previews can hot-reload,
# which moves every symbol out of the binary this script measures. Counting that would report a
# comfortable zero for all four budgets and mean nothing.
if otool -L "$binary" | grep -q "SpeechRecognition.debug.dylib"; then
  echo "error: $app_path is a Debug build (links the debug dylib), whose main binary is a stub." >&2
  echo "       Run without --app to build Release, or pass a Release/TestFlight bundle." >&2
  exit 2
fi

# --- measure -----------------------------------------------------------------------------------

# `otool -l` prints section sizes as hex; an absent section prints nothing, which is zero.
section_pointer_count() {
  local arch="$1" section="$2" size
  size="$(otool -arch "$arch" -l "$binary" \
    | grep -A4 "sectname $section" \
    | awk '/^ *size /{print $2; exit}')"
  if [[ -z "$size" ]]; then
    echo 0
  else
    echo $(( size / 8 ))
  fi
}

if [[ -d "$app_path/Frameworks" ]]; then
  embedded_frameworks="$(find "$app_path/Frameworks" -maxdepth 1 -name '*.framework' | wc -l | tr -d ' ')"
else
  embedded_frameworks=0
fi

status=0
report() {
  local label="$1" actual="$2" budget="$3"
  if (( actual > budget )); then
    printf '  %-24s %6s   budget %-6s  ✗ over by %s\n' "$label" "$actual" "$budget" "$(( actual - budget ))"
    status=1
  else
    printf '  %-24s %6s   budget %-6s  ok\n' "$label" "$actual" "$budget"
  fi
}

echo
echo "Launch budget — $(basename "$app_path")"
report "embedded frameworks" "$embedded_frameworks" "$MAX_EMBEDDED_FRAMEWORKS"

for arch in $(lipo -archs "$binary"); do
  echo "  ── $arch"
  report "static initializers" "$(section_pointer_count "$arch" __mod_init_func)" "$MAX_STATIC_INITIALIZERS"
  report "non-lazy ObjC classes" "$(section_pointer_count "$arch" __objc_nlclslist)" "$MAX_NON_LAZY_CLASSES"
  report "linked dylibs" "$(otool -arch "$arch" -L "$binary" | grep -c $'^\t' || true)" "$MAX_LINKED_DYLIBS"
done

echo
if (( status != 0 )); then
  echo "Launch budget exceeded. Either undo the cost or raise the budget in $(basename "${BASH_SOURCE[0]}")"
  echo "in the same commit, saying what it buys."
fi
exit "$status"
