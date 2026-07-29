#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

verifier="$temporary_directory/bundled-key-format-verifier"
swiftc \
  -parse-as-library \
  "$repository_root/SpeechRecognition/BundledAPIKey.swift" \
  "$repository_root/Scripts/verify-bundled-key-format.swift" \
  -o "$verifier"

valid_key="sk-ant-test"
valid_mask="0000000000000000000000"
expected_payload="v1.$valid_mask.736b2d616e742d74657374"
generated_payload="$(
  swift "$repository_root/Scripts/generate-bundled-key.swift" --emit-test-vector
)"

if [[ "$generated_payload" != "$expected_payload" ]]; then
  echo "error: generator output does not match the v1 golden vector" >&2
  exit 1
fi

decoded_key="$($verifier decode "$generated_payload")"
if [[ "$decoded_key" != "$valid_key" ]]; then
  echo "error: runtime decoder does not match the v1 golden vector" >&2
  exit 1
fi

env \
  CONFIGURATION=TestFlight \
  BUNDLED_ANTHROPIC_API_KEY_PAYLOAD="$generated_payload" \
  bash "$repository_root/Scripts/validate-bundled-key.sh" >/dev/null

expect_rejected() {
  local payload="$1"
  if env \
    CONFIGURATION=TestFlight \
    BUNDLED_ANTHROPIC_API_KEY_PAYLOAD="$payload" \
    bash "$repository_root/Scripts/validate-bundled-key.sh" >/dev/null 2>&1
  then
    echo "error: build validator accepted malformed payload: $payload" >&2
    exit 1
  fi
  if "$verifier" decode "$payload" >/dev/null 2>&1; then
    echo "error: runtime decoder accepted malformed payload: $payload" >&2
    exit 1
  fi
}

invalid_payloads=(
  "$generated_payload."
  "v1.0000000000000000000000.736b2d616e742df09f9490"
  "v1.000000000000000000.6e6f742d612d6b6579"
  "v1.00.ff"
  "v1.gg.00"
  "v1.00.0000"
  "v2.00.00"
)

for payload in "${invalid_payloads[@]}"; do
  expect_rejected "$payload"
done

if env \
  CONFIGURATION=Staging \
  BUNDLED_ANTHROPIC_API_KEY_PAYLOAD="$generated_payload" \
  bash "$repository_root/Scripts/validate-bundled-key.sh" >/dev/null 2>&1
then
  echo "error: unknown build configuration accepted a bundled payload" >&2
  exit 1
fi

env \
  CONFIGURATION=Staging \
  BUNDLED_ANTHROPIC_API_KEY_PAYLOAD="" \
  bash "$repository_root/Scripts/validate-bundled-key.sh" >/dev/null

if env \
  CONFIGURATION=Release \
  BUNDLED_ANTHROPIC_API_KEY_PAYLOAD="$generated_payload" \
  bash "$repository_root/Scripts/validate-bundled-key.sh" >/dev/null 2>&1
then
  echo "error: Release configuration accepted a bundled payload" >&2
  exit 1
fi

if env \
  CONFIGURATION=TestFlight \
  BUNDLED_ANTHROPIC_API_KEY_PAYLOAD="" \
  bash "$repository_root/Scripts/validate-bundled-key.sh" >/dev/null 2>&1
then
  echo "error: TestFlight configuration accepted a missing payload" >&2
  exit 1
fi

echo "Bundled key generator, runtime decoder, and build validator agree."
