#!/usr/bin/env bash
# examples/ios-llama/smoke.sh
#
# Smoke test for ios-llama. iOS native examples can only run on a Mac
# host; on Windows / Linux this script prints a skip message and
# exits 0 (so `scripts/run-example-smoke.sh` doesn't fail the host).
#
# On Mac (or invoked via `ssh mac`), runs `xcodebuild test` against
# the Tests/IOSLlamaAppTests target on an iPhone 16 simulator. The test
# itself reads SMOKE_MODEL_URL / SMOKE_MODEL_SHA256 from the env or
# scripts/smoke.local.env and skips cleanly when neither is populated.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[ios-llama] iOS smoke must run on Mac via ssh mac — skipping on $(uname -s)"
  exit 0
fi

cd "$(dirname "$0")"

DEST="${IOS_DEST:-platform=iOS Simulator,name=iPhone 16,OS=18.5}"

xcodebuild test \
  -scheme IOSLlamaApp \
  -destination "$DEST" \
  -configuration Debug \
  -resultBundlePath ./build/SmokeResults.xcresult \
  | tee ./build/smoke.log
