#!/usr/bin/env bash
# scripts/mac-side-build.sh — Run on Mac via SSH. Builds an iOS target.
set -euo pipefail
TARGET="${1:?usage: mac-side-build.sh <target> [filter]}"

DEST="${IOS_DEST:-platform=iOS Simulator,name=iPhone 16,OS=18.5}"

case "$TARGET" in
  ios-foundation-core)
    cd "packages/dvai-bridge-ios-foundation-core"
    xcodebuild build \
      -scheme DVAIFoundationCore \
      -destination "$DEST" \
      -configuration Debug
    ;;
  ios-llama-core)
    cd "packages/dvai-bridge-ios-llama-core"
    xcodebuild build \
      -scheme DVAILlamaCore \
      -destination "$DEST" \
      -configuration Debug
    ;;
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
  capacitor-mediapipe)
    cd "packages/dvai-bridge-capacitor-mediapipe/ios"
    xcodebuild build \
      -scheme DVAICapacitorMediaPipe \
      -destination "$DEST" \
      -configuration Debug
    ;;
  *) echo "Unknown target: $TARGET" >&2; exit 2 ;;
esac
