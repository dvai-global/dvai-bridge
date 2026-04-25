#!/usr/bin/env bash
# scripts/mac-side-build.sh — Run on Mac via SSH. Builds an iOS target.
set -euo pipefail
TARGET="${1:?usage: mac-side-build.sh <target> [filter]}"

DEST="${IOS_DEST:-platform=iOS Simulator,name=iPhone 16,OS=18.5}"

case "$TARGET" in
  capacitor-llama)
    cd "packages/dvai-bridge-capacitor-llama/ios"
    xcodebuild build \
      -scheme DVAICapacitorLlama \
      -destination "$DEST" \
      -configuration Debug
    ;;
  capacitor-foundation)
    cd "packages/dvai-bridge-capacitor-foundation/ios"
    xcodebuild build \
      -scheme DVAICapacitorFoundation \
      -destination "$DEST" \
      -configuration Debug
    ;;
  *) echo "Unknown target: $TARGET" >&2; exit 2 ;;
esac
