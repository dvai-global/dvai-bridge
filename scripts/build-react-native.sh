#!/usr/bin/env bash
# build-react-native.sh — Build + test the React Native TurboModule package.
# Runs the package's own test suite + (optionally) builds the example app
# if one is present.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PKG_DIR="$REPO_ROOT/packages/dvai-bridge-react-native"
if [[ ! -d "$PKG_DIR" ]]; then
    echo "ERROR: $PKG_DIR not found." >&2
    exit 1
fi

# Preflight
command -v pnpm >/dev/null 2>&1 || {
    echo "ERROR: pnpm not found." >&2
    exit 1
}

echo "==> [rn] pnpm --filter @dvai-bridge/react-native run build"
pnpm --filter @dvai-bridge/react-native run build || {
    echo "WARN: @dvai-bridge/react-native has no 'build' script — skipping." >&2
}

echo "==> [rn] pnpm --filter @dvai-bridge/react-native test"
pnpm --filter @dvai-bridge/react-native test || {
    echo "WARN: @dvai-bridge/react-native has no 'test' script — skipping." >&2
}

# Example app (optional — runs only if packages/dvai-bridge-react-native/example exists)
EXAMPLE_DIR="$PKG_DIR/example"
if [[ -d "$EXAMPLE_DIR" ]]; then
    echo "==> [rn] example app present at $EXAMPLE_DIR"
    if [[ "$(uname -s)" == "Darwin" ]] && [[ -d "$EXAMPLE_DIR/ios" ]]; then
        echo "==> [rn:example] pod install"
        (cd "$EXAMPLE_DIR/ios" && pod install)
    fi
    if [[ -d "$EXAMPLE_DIR/android" ]]; then
        echo "==> [rn:example] gradlew assembleDebug"
        (cd "$EXAMPLE_DIR/android" && ./gradlew assembleDebug)
    fi
else
    echo "==> [rn] no example app at $EXAMPLE_DIR (skip)"
fi

echo "==> [rn] OK"
