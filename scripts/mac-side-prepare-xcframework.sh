#!/usr/bin/env bash
# scripts/mac-side-prepare-xcframework.sh
#
# Builds llama.xcframework from the pinned llama.cpp submodule using
# upstream's build-xcframework.sh. The xcframework is gitignored; rebuild
# this artifact whenever the llama.cpp submodule SHA changes.
#
# Why we need this: upstream llama.cpp removed Package.swift after tag
# b4823 (March 2025) in favor of build-xcframework.sh. Our outer
# packages/dvai-bridge-capacitor-llama/ios/Package.swift declares a
# .binaryTarget pointing at the xcframework path produced by this script.
#
# Run on Mac: bash scripts/mac-side-prepare-xcframework.sh
#
# Honors:
#   FORCE=1   -> rebuild even if the xcframework already exists.
set -euo pipefail

LLAMA_DIR="packages/dvai-bridge-capacitor-llama/native/llama.cpp"
XCF_PATH="$LLAMA_DIR/build-apple/llama.xcframework"

if [ -d "$XCF_PATH" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "[prepare-xcframework] $XCF_PATH already exists; skipping rebuild."
    echo "[prepare-xcframework] Set FORCE=1 to rebuild from scratch."
    exit 0
fi

# Make sure homebrew tools (cmake) are on PATH for non-interactive shells.
if [ -x /opt/homebrew/bin/cmake ] && ! command -v cmake >/dev/null 2>&1; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "[prepare-xcframework] cmake not found on PATH. Install via 'brew install cmake'." >&2
    exit 1
fi

cd "$LLAMA_DIR"
echo "[prepare-xcframework] Running build-xcframework.sh (this takes ~5-15 min)..."
bash build-xcframework.sh
echo "[prepare-xcframework] Done -> $LLAMA_DIR/build-apple/llama.xcframework"
