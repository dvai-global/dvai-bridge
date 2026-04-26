#!/usr/bin/env bash
# scripts/mac-side-test.sh — Run on Mac via SSH. Runs XCTest for a target.
#
# Sources scripts/smoke.local.env (gitignored, per-developer) for
# real-model smoke env vars and forwards them to the iOS Simulator
# child via xcrun's SIMCTL_CHILD_* convention. CI workflow injects the
# same names directly via GitHub Actions secrets, so the smoke.local.env
# file is only needed for local Mac development.
set -euo pipefail
TARGET="${1:?usage: mac-side-test.sh <target> [filter]}"
FILTER="${2:-}"

DEST="${IOS_DEST:-platform=iOS Simulator,name=iPhone 16,OS=18.5}"

# Load per-developer smoke env if present. The file uses standard
# `KEY=VALUE` shell syntax; we `source` it inside a subshell-friendly
# block so it doesn't pollute the calling shell.
if [ -f "scripts/smoke.local.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "scripts/smoke.local.env"; set +a
fi

# Forward every SMOKE_* var into the iOS Simulator child process so
# `ProcessInfo.processInfo.environment` in the test target sees them.
# xcrun simctl strips the SIMCTL_CHILD_ prefix when launching the app.
for var in $(compgen -v | grep '^SMOKE_'); do
    export "SIMCTL_CHILD_${var}"="${!var}"
done

case "$TARGET" in
  capacitor-llama)
    cd "packages/dvai-bridge-capacitor-llama/ios"
    SCHEME="DVAICapacitorLlama"
    ;;
  capacitor-foundation)
    cd "packages/dvai-bridge-capacitor-foundation/ios"
    SCHEME="DVAICapacitorFoundation"
    ;;
  capacitor-mediapipe)
    cd "packages/dvai-bridge-capacitor-mediapipe/ios"
    SCHEME="DVAICapacitorMediaPipe"
    ;;
  *) echo "Unknown target: $TARGET" >&2; exit 2 ;;
esac

# xcodebuild aborts with exit 64 if the result bundle already exists; clear it.
rm -rf build/test-results.xcresult

if [ -n "$FILTER" ]; then
  xcodebuild test \
    -scheme "$SCHEME" \
    -destination "$DEST" \
    -only-testing:"$FILTER" \
    -resultBundlePath build/test-results.xcresult
else
  xcodebuild test \
    -scheme "$SCHEME" \
    -destination "$DEST" \
    -resultBundlePath build/test-results.xcresult
fi
