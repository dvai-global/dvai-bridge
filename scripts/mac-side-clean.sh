#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:?usage: mac-side-clean.sh <target>}"

case "$TARGET" in
  capacitor-llama)
    cd "packages/dvai-bridge-capacitor-llama/ios"
    xcodebuild clean -scheme DVAICapacitorLlama
    ;;
  capacitor-foundation)
    cd "packages/dvai-bridge-capacitor-foundation/ios"
    xcodebuild clean -scheme DVAICapacitorFoundation
    ;;
  *) echo "Unknown target: $TARGET" >&2; exit 2 ;;
esac
