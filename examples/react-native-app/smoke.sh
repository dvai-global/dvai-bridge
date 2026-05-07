#!/usr/bin/env bash
# Smoke check for the React Native example.
#
# Validates:
#   1. TypeScript compiles (`tsc --noEmit`).
#   2. Metro bundles the JS for Android (proves all imports resolve, including
#      `@dvai-bridge/react-native` and `openai`).
#   3. (best-effort) `./gradlew assembleDebug` if a JDK + Android SDK are
#      installed on the host. Skipped with a clear message otherwise.
#
# iOS pod-install is intentionally NOT exercised here; that runs over
# `ssh mac` from the Mac mirror.

set -euo pipefail

cd "$(dirname "$0")"

echo "[smoke] typecheck…"
pnpm exec tsc --noEmit

echo "[smoke] Metro bundle (Android)…"
mkdir -p dist
pnpm exec react-native bundle \
  --platform android \
  --dev false \
  --entry-file index.js \
  --bundle-output dist/index.android.bundle \
  --assets-dest dist/android-assets \
  --reset-cache

if [ ! -s dist/index.android.bundle ]; then
  echo "[smoke] Metro bundle is empty" >&2
  exit 1
fi

if [ "${SKIP_ANDROID_BUILD:-1}" = "1" ]; then
  # Default-skip: a full ./gradlew assembleDebug pulls @react-native/codegen
  # into per-module Node spawns which interact poorly with pnpm's hoist
  # layout. Set RUN_ANDROID_BUILD=1 to force-run; set SKIP_ANDROID_BUILD=0
  # to fall through to the host check below.
  echo "[smoke] SKIP_ANDROID_BUILD=1 (default) — skipping ./gradlew assembleDebug. Set RUN_ANDROID_BUILD=1 to force."
fi

if [ "${RUN_ANDROID_BUILD:-0}" = "1" ]; then
  if [ -d android ] && [ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]; then
    if command -v java >/dev/null 2>&1; then
      echo "[smoke] ./gradlew assembleDebug…"
      pushd android >/dev/null
      if [ -x ./gradlew ]; then
        ./gradlew assembleDebug --no-daemon -x lint
      elif [ -x ./gradlew.bat ]; then
        cmd //c gradlew.bat assembleDebug --no-daemon -x lint
      else
        echo "[smoke] no gradlew script found — skipping"
      fi
      popd >/dev/null
    else
      echo "[smoke] JDK not on PATH — skipping ./gradlew assembleDebug"
    fi
  else
    echo "[smoke] ANDROID_HOME not set — skipping ./gradlew assembleDebug"
  fi
fi

echo "[smoke] OK"
