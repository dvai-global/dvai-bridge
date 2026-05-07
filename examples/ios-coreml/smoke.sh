#!/usr/bin/env bash
# examples/ios-coreml/smoke.sh
#
# Smoke for ios-coreml. Skips on non-Mac; on Mac runs xcodebuild test
# against an iPhone 16 simulator. The test itself is currently gated
# off via XCTSkip (the .coreml backend has a known IRValue-format crash
# at first prediction — see docs/guide/ios-native-sdk.md#known-issues),
# so this passes as a clean skip until the upstream CoreML bug is fixed.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[ios-coreml] iOS smoke must run on Mac via ssh mac — skipping on $(uname -s)"
  exit 0
fi

cd "$(dirname "$0")"

DEST="${IOS_DEST:-platform=iOS Simulator,name=iPhone 16,OS=18.5}"

xcodebuild test \
  -scheme IOSCoreMLApp \
  -destination "$DEST" \
  -configuration Debug \
  -resultBundlePath ./build/SmokeResults.xcresult \
  | tee ./build/smoke.log
