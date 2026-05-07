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
#
# Robolectric @ compileSdk 36 requires **JDK 21+** at test runtime, so we
# prefer a Homebrew openjdk install (which usually has the latest stable)
# over Android Studio's bundled JBR (often pinned to 17 in older Studio
# releases). Fall back to Studio's JBR only if it's also 21+.
if [ -z "${JAVA_HOME:-}" ]; then
    HOMEBREW_OPENJDK_GLOB=(/opt/homebrew/Cellar/openjdk/*/libexec/openjdk.jdk/Contents/Home)
    DEFAULT_JBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"

    PICKED=""
    # Walk newest-first; the glob is alphabetical, so reverse-sort gets latest.
    if [ -x "${HOMEBREW_OPENJDK_GLOB[0]}/bin/java" ]; then
        for candidate in $(printf '%s\n' "${HOMEBREW_OPENJDK_GLOB[@]}" | sort -r); do
            if [ -x "$candidate/bin/java" ]; then
                PICKED="$candidate"
                break
            fi
        done
    fi
    if [ -z "$PICKED" ] && [ -x "$DEFAULT_JBR/bin/java" ]; then
        PICKED="$DEFAULT_JBR"
    fi
    if [ -z "$PICKED" ]; then
        echo "[android-publish-local] JAVA_HOME unset and no JDK found at Homebrew openjdk path or Android Studio JBR." >&2
        echo "                        Install JDK 21+ (e.g. \`brew install openjdk\`) and re-run." >&2
        exit 1
    fi
    export JAVA_HOME="$PICKED"

    # Sanity-check that the picked JDK is at least 21 (Robolectric @ SDK 36 requirement).
    JAVA_MAJOR="$($JAVA_HOME/bin/java -version 2>&1 | awk -F '"' '/version/ {split($2, a, "."); print a[1]}')"
    if [ -n "$JAVA_MAJOR" ] && [ "$JAVA_MAJOR" -lt 21 ]; then
        echo "[android-publish-local] Picked JDK $JAVA_MAJOR at $JAVA_HOME, but Robolectric needs 21+." >&2
        echo "                        Install a newer JDK (\`brew install openjdk\`) and re-run." >&2
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
    "dvai-bridge-android-litert-core"
    "dvai-bridge-android"
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
        # `compileSdkOverride` is forwarded so Windows hosts can fall to
        # compileSdk 35 (AGP 9.2.0 has a parseLocalResources bug against
        # android-36's public-final.xml on Windows). Mac/Linux ignore it
        # unless explicitly passed by the caller. See
        # packages/dvai-bridge-android-shared-core/android/build.gradle for
        # the rationale.
        ./gradlew publishToMavenLocal ${COMPILE_SDK_OVERRIDE:+-PcompileSdkOverride=$COMPILE_SDK_OVERRIDE} --console=plain --quiet
    )
done

echo
echo "[android-publish-local] All packages published. Verify with:"
echo "    ls ~/.m2/repository/co/deepvoiceai/"
