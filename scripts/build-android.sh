#!/usr/bin/env bash
# build-android.sh — Build + test the 5 Android Gradle modules.
# Runs on Mac / Linux / Windows (with bash + JDK + Android SDK installed).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Preflight
if [[ -z "${JAVA_HOME:-}" ]]; then
    echo "ERROR: JAVA_HOME not set. Install JDK 23 (e.g. via 'brew install openjdk@23' or download from Adoptium) and export JAVA_HOME." >&2
    exit 1
fi
if [[ -z "${ANDROID_HOME:-}" ]]; then
    echo "ERROR: ANDROID_HOME not set. Install Android Studio + SDK 36 and export ANDROID_HOME." >&2
    exit 1
fi

# Modules in dep order: shared-core first, then the 3 backend cores in parallel-safe order, then umbrella.
MODULES=(
    "dvai-bridge-android-shared-core"
    "dvai-bridge-android-llama-core"
    "dvai-bridge-android-mediapipe-core"
    "dvai-bridge-android-litert-core"
    "dvai-bridge-android"
)

for module in "${MODULES[@]}"; do
    module_dir="$REPO_ROOT/packages/$module/android"
    if [[ ! -d "$module_dir" ]]; then
        echo "WARN: $module_dir not found — skipping" >&2
        continue
    fi

    echo "==> [android:$module] gradlew assemble test"
    (cd "$module_dir" && ./gradlew assemble test)
done

echo "==> [android] OK (5/5 modules)"
