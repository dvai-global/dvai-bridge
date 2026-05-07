#!/usr/bin/env bash
# examples/android-llama/smoke.sh — Phase 2 Task 3.
#
# Runs the JVM unit smoke (always) and the connectedAndroidTest suite
# when an emulator/device is connected. Exits 0 if everything that ran
# passed; exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." >/dev/null 2>&1 && pwd)"

# 0. Make sure the SDK AARs are in mavenLocal. Skip if already present —
#    the publish takes ~5 minutes due to the llama.cpp NDK compile.
M2_DIR="${USERPROFILE:-$HOME}/.m2/repository/co/deepvoiceai"
M2_DIR_NORM="$(echo "$M2_DIR" | sed 's|\\|/|g')"
if [ ! -d "$M2_DIR_NORM/dvai-bridge" ]; then
    echo "[smoke] mavenLocal missing dvai-bridge; running android-publish-local first."
    if [ "$(uname -s)" = "Linux" ] || [ "$(uname -s)" = "Darwin" ]; then
        bash "$REPO_ROOT/scripts/android-publish-local.sh"
    else
        # Windows / Git-Bash — defer to PowerShell.
        powershell.exe -ExecutionPolicy Bypass -File "$REPO_ROOT\\scripts\\android-publish-local.ps1"
    fi
fi

cd "$SCRIPT_DIR"

# 1. JVM unit tests — always run.
echo "[smoke] ./gradlew assembleDebug test"
./gradlew assembleDebug test --console=plain

# 2. Connected device tests — opt-in based on `adb devices` output.
if command -v adb >/dev/null 2>&1; then
    if adb devices | awk 'NR>1 && /device$/ {found=1} END {exit !found}'; then
        echo "[smoke] device detected; running connectedAndroidTest"
        ./gradlew connectedAndroidTest --console=plain || {
            echo "[smoke] connectedAndroidTest failed — usually because the model"
            echo "        file is not pushed. See the README for adb-push instructions."
            exit 1
        }
    else
        echo "[smoke] no device/emulator connected; skipping connectedAndroidTest."
    fi
else
    echo "[smoke] adb not on PATH; skipping connectedAndroidTest."
fi

echo "[smoke] android-litert smoke OK."
