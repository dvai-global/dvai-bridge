#!/usr/bin/env bash
# examples/ios-mlx/smoke.sh
#
# Smoke for ios-mlx. Skips on non-Mac. On Mac, runs xcodebuild test
# against an iPhone 16 simulator. The MLX backend is Apple-Silicon-only
# at runtime — Intel Mac hosts and Intel simulator destinations will
# XCTSkip cleanly.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[ios-mlx] iOS smoke must run on Mac via ssh mac — skipping on $(uname -s)"
  exit 0
fi

cd "$(dirname "$0")"

DEST="${IOS_DEST:-platform=iOS Simulator,name=iPhone 16,OS=18.5}"

xcodebuild test \
  -scheme IOSMLXApp \
  -destination "$DEST" \
  -configuration Debug \
  -resultBundlePath ./build/SmokeResults.xcresult \
  | tee ./build/smoke.log
