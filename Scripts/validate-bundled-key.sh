#!/bin/bash

set -u

configuration="${CONFIGURATION:-}"
payload="${BUNDLED_ANTHROPIC_API_KEY_PAYLOAD:-}"

payload_error=""
if [[ -z "$payload" ]]; then
  payload_error="the bundled Anthropic key payload is missing"
else
  IFS='.' read -r version mask ciphertext extra <<< "$payload"
  if [[ "$version" != "v1" || -n "${extra:-}" ]]; then
    payload_error="the bundled Anthropic key payload has an unsupported format"
  elif [[ -z "$mask" || -z "$ciphertext" ]]; then
    payload_error="the bundled Anthropic key payload is empty"
  elif [[ ! "$mask" =~ ^[[:xdigit:]]+$ || ! "$ciphertext" =~ ^[[:xdigit:]]+$ ]]; then
    payload_error="the bundled Anthropic key payload contains invalid hex"
  elif (( ${#mask} % 2 != 0 || ${#ciphertext} % 2 != 0 )); then
    payload_error="the bundled Anthropic key payload contains incomplete bytes"
  elif [[ ${#mask} -ne ${#ciphertext} ]]; then
    payload_error="the bundled Anthropic key mask and ciphertext lengths differ"
  else
    plaintext=""
    for (( offset = 0; offset < ${#mask}; offset += 2 )); do
      mask_byte=$((16#${mask:offset:2}))
      ciphertext_byte=$((16#${ciphertext:offset:2}))
      plaintext_byte=$((mask_byte ^ ciphertext_byte))
      if (( plaintext_byte < 33 || plaintext_byte > 126 )); then
        payload_error="the bundled Anthropic key payload does not decode to printable ASCII"
        break
      fi
      printf -v octal '%03o' "$plaintext_byte"
      printf -v character '%b' "\\$octal"
      plaintext+="$character"
    done
    if [[ -z "$payload_error" && "$plaintext" != sk-ant-* ]]; then
      payload_error="the bundled Anthropic key payload does not decode to an Anthropic API key"
    fi
  fi
fi

case "$configuration" in
  TestFlight)
    if [[ -n "$payload_error" ]]; then
      echo "error: $payload_error. Run: swift Scripts/generate-bundled-key.swift"
      exit 1
    fi
    ;;
  Debug)
    if [[ -n "$payload_error" ]]; then
      echo "warning: $payload_error. Run: swift Scripts/generate-bundled-key.swift"
    fi
    ;;
  Release)
    if [[ -n "$payload" ]]; then
      echo "error: Release/App Store builds must not contain a bundled Anthropic key payload."
      exit 1
    fi
    ;;
esac
