#!/bin/bash
# Regenerates SpeechRecognition/Assets.xcassets/*.appiconset from the shared icon artwork.
# Run from the repository root after changing AppIconArtwork.swift.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

swiftc -O \
  "$root/Scripts/render-app-icons.swift" \
  "$root/SpeechRecognition/AppIconArtwork.swift" \
  -o "$build/render-app-icons"

cd "$root"
"$build/render-app-icons"
