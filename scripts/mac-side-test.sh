#!/usr/bin/env bash
# scripts/mac-side-test.sh — Run on Mac via SSH. Runs XCTest for a target.
#
# Sources scripts/smoke.local.env (gitignored, per-developer) for
# real-model smoke env vars and forwards them to the test process
# via Xcode's TEST_RUNNER_<NAME>=<VALUE> build-setting convention.
# At test runtime, ProcessInfo.processInfo.environment sees each
# SMOKE_* key with the TEST_RUNNER_ prefix stripped, so the test
# code reads `env["SMOKE_MODEL_URL"]` etc. unchanged.
#
# CI workflow injects the same names directly via GitHub Actions
# secrets, so smoke.local.env is only needed for local Mac dev.
set -euo pipefail
TARGET="${1:?usage: mac-side-test.sh <target> [filter]}"
FILTER="${2:-}"
# A FILTER value beginning with `!` is treated as a skip filter
# (`-skip-testing:<rest>`). Useful to run the full suite minus a
# long-running smoke class without listing every other class by hand.
SKIP_FILTER=""
if [ -n "$FILTER" ] && [ "${FILTER:0:1}" = "!" ]; then
  SKIP_FILTER="${FILTER:1}"
  FILTER=""
fi

DEST="${IOS_DEST:-platform=iOS Simulator,name=iPhone 16,OS=18.5}"

# Load per-developer smoke env if present. The file uses standard
# `KEY=VALUE` shell syntax; we `source` it inside a subshell-friendly
# block so it doesn't pollute the calling shell.
if [ -f "scripts/smoke.local.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "scripts/smoke.local.env"; set +a
fi

# Build the TEST_RUNNER_<NAME>=<VAL> argv list so xcodebuild test
# injects each SMOKE_* var into the test process at runtime.
# `set | grep ^SMOKE_` is portable across bash/zsh and works under
# bash's strict mode (set -euo pipefail).
RUNNER_ENV_ARGS=()
while IFS='=' read -r name _; do
    if [ -n "$name" ]; then
        RUNNER_ENV_ARGS+=("TEST_RUNNER_${name}=${!name}")
    fi
done < <(set | grep '^SMOKE_' || true)

case "$TARGET" in
  ios-foundation-core)
    cd "packages/dvai-bridge-ios-foundation-core"
    # Single-library packages don't get a `-Package` umbrella scheme; the
    # bare library scheme works because there's only one product to build.
    SCHEME="DVAIFoundationCore"
    ;;
  ios-llama-core)
    cd "packages/dvai-bridge-ios-llama-core"
    # Umbrella `*-Package` scheme includes every target (Swift, ObjC, tests).
    # The bare `DVAILlamaCore` scheme is library-only and rejects the test
    # action with "Scheme DVAILlamaCore is not currently configured for the
    # test action" because the package now exposes multiple library products.
    SCHEME="DVAILlamaCore-Package"
    ;;
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

XCODEBUILD_ARGS=(
  test
  -scheme "$SCHEME"
  -destination "$DEST"
  -resultBundlePath build/test-results.xcresult
)
if [ -n "$FILTER" ]; then
  XCODEBUILD_ARGS+=(-only-testing:"$FILTER")
fi
if [ -n "$SKIP_FILTER" ]; then
  XCODEBUILD_ARGS+=(-skip-testing:"$SKIP_FILTER")
fi
xcodebuild "${XCODEBUILD_ARGS[@]}" "${RUNNER_ENV_ARGS[@]}"
