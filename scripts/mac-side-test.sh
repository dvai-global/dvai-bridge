#!/usr/bin/env bash
# scripts/mac-side-test.sh — Run on Mac via SSH. Runs XCTest for a target.
set -euo pipefail
TARGET="${1:?usage: mac-side-test.sh <target> [filter]}"
FILTER="${2:-}"

case "$TARGET" in
  capacitor-llama)
    cd "packages/dvai-bridge-capacitor-llama/ios"
    SCHEME="DVAICapacitorLlama"
    ;;
  capacitor-foundation)
    cd "packages/dvai-bridge-capacitor-foundation/ios"
    SCHEME="DVAICapacitorFoundation"
    ;;
  *) echo "Unknown target: $TARGET" >&2; exit 2 ;;
esac

if [ -n "$FILTER" ]; then
  xcodebuild test \
    -scheme "$SCHEME" \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' \
    -only-testing:"$FILTER" \
    -resultBundlePath build/test-results.xcresult
else
  xcodebuild test \
    -scheme "$SCHEME" \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' \
    -resultBundlePath build/test-results.xcresult
fi
