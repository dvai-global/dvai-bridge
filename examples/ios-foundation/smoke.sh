#!/usr/bin/env bash
# examples/ios-foundation/smoke.sh
#
# Smoke for ios-foundation. Skips on non-Mac; on Mac runs xcodebuild
# test against an iPhone 16 simulator. The test itself is gated to
# iOS 26+ at runtime (XCTSkip on older simulators), so this still
# passes on iOS 18.5 simulators — just as a skip.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[ios-foundation] iOS smoke must run on Mac via ssh mac — skipping on $(uname -s)"
  exit 0
fi

cd "$(dirname "$0")"

# Default to iPhone 16 / iOS 18.5; if a Mac has the iOS 26 simulator
# installed, point IOS_DEST at it (e.g. "...,OS=26.0") to actually
# exercise the Foundation backend instead of skipping.
DEST="${IOS_DEST:-platform=iOS Simulator,name=iPhone 16,OS=18.5}"

mkdir -p ./build
xcodebuild test \
  -scheme ios-foundation \
  -destination "$DEST" \
  -configuration Debug \
  -resultBundlePath ./build/SmokeResults.xcresult \
  | tee ./build/smoke.log
