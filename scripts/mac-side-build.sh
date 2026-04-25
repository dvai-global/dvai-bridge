#!/usr/bin/env bash
# scripts/mac-side-build.sh — Run on Mac via SSH. Builds an iOS target.
set -euo pipefail
TARGET="${1:?usage: mac-side-build.sh <target> [filter]}"

case "$TARGET" in
  capacitor-llama)
    cd "packages/dvai-bridge-capacitor-llama/ios"
    xcodebuild build \
      -scheme DVAICapacitorLlama \
      -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' \
      -configuration Debug
    ;;
  capacitor-foundation)
    cd "packages/dvai-bridge-capacitor-foundation/ios"
    xcodebuild build \
      -scheme DVAICapacitorFoundation \
      -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' \
      -configuration Debug
    ;;
  *) echo "Unknown target: $TARGET" >&2; exit 2 ;;
esac
