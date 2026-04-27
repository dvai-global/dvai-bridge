#!/usr/bin/env bash
# scripts/android-publish-local.sh — Run on Mac.
#
# Publishes every Android module in the monorepo to ~/.m2/repository
# (mavenLocal) in dependency order so cross-package `implementation
# 'co.deepvoiceai:android-shared-core:<version>'` style dependencies
# resolve cleanly during dev.
#
# Order matters:
#   1. android-shared-core      (foundation; depends on nothing)
#   2. android-llama-core       (depends on shared-core)
#      android-mediapipe-core   (depends on shared-core)
#      android-litert-core      (depends on shared-core)         [Phase 3D Task 5+]
#   3. dvai-bridge-android      (depends on all of the above)    [Phase 3D Task 10+]
#
# Phase 3D Task 4 — initial scope (covers what currently exists; the
# litert-core + umbrella entries are commented out and re-enabled by
# the tasks that scaffold them).
#
# Required env (set automatically if Android Studio is at the default
# location; override on machines where it's installed elsewhere):
#   JAVA_HOME    — JDK 17+ (Gradle 9.4.x requires it)
#   ANDROID_HOME — Android SDK with platforms 36 and build-tools

set -euo pipefail

# Resolve paths relative to repo root no matter where the script is invoked from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

# Best-effort defaults for JAVA_HOME / ANDROID_HOME.
if [ -z "${JAVA_HOME:-}" ]; then
    DEFAULT_JBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    if [ -x "$DEFAULT_JBR/bin/java" ]; then
        export JAVA_HOME="$DEFAULT_JBR"
    else
        echo "[android-publish-local] JAVA_HOME unset and Android Studio default JBR not found." >&2
        echo "                        Set JAVA_HOME to a JDK 17+ install before re-running." >&2
        exit 1
    fi
fi
if [ -z "${ANDROID_HOME:-}" ]; then
    DEFAULT_SDK="$HOME/Library/Android/sdk"
    if [ -d "$DEFAULT_SDK" ]; then
        export ANDROID_HOME="$DEFAULT_SDK"
    else
        echo "[android-publish-local] ANDROID_HOME unset and ~/Library/Android/sdk not found." >&2
        echo "                        Set ANDROID_HOME to your Android SDK root before re-running." >&2
        exit 1
    fi
fi

echo "[android-publish-local] JAVA_HOME    = $JAVA_HOME"
echo "[android-publish-local] ANDROID_HOME = $ANDROID_HOME"

# Each entry: directory under packages/.
PACKAGES=(
    "dvai-bridge-android-shared-core"
    "dvai-bridge-android-llama-core"
    "dvai-bridge-android-mediapipe-core"
    # "dvai-bridge-android-litert-core"   # enabled by Phase 3D Task 5
    # "dvai-bridge-android"               # enabled by Phase 3D Task 10
)

for PKG in "${PACKAGES[@]}"; do
    PKG_DIR="$REPO_ROOT/packages/$PKG/android"
    if [ ! -d "$PKG_DIR" ]; then
        echo "[android-publish-local] $PKG not present yet; skipping" >&2
        continue
    fi
    echo
    echo "===================================================================="
    echo "[android-publish-local] $PKG -> mavenLocal"
    echo "===================================================================="
    (
        cd "$PKG_DIR"
        chmod +x ./gradlew
        ./gradlew publishToMavenLocal --console=plain --quiet
    )
done

echo
echo "[android-publish-local] All packages published. Verify with:"
echo "    ls ~/.m2/repository/co/deepvoiceai/"
