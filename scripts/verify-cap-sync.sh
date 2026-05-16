#!/usr/bin/env bash
# scripts/verify-cap-sync.sh
#
# Bootstraps a throw-away Capacitor host app, installs all current
# Phase 3A packages from the local monorepo, runs `npx cap sync`, then
# proves both Android assembleDebug and iOS Pod install resolve cleanly
# against the new package layout.
#
# This is the regression test that protects against "core package's
# Gradle module path doesn't get picked up by cap sync" — a real risk
# of the slim-install model where the wrapper points at a sibling
# core package via project-relative paths.
#
# Usage: bash scripts/verify-cap-sync.sh
#
# Exit codes:
#   0 — both Android and iOS resolved cleanly (or skipped iOS if not on Mac)
#   non-zero — something broke; output points at the failure
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
echo "[verify-cap-sync] using $TMP"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
mkdir www
echo '<html><head><title>cap-sync test</title></head><body></body></html>' > www/index.html

cat > package.json <<'EOF'
{
  "name": "dvai-cap-sync-test",
  "version": "1.0.0",
  "private": true
}
EOF

# Initialize Capacitor
npx --yes @capacitor/cli@8 init dvai-cap-test com.dvai.captest --web-dir www

# Install all Phase 3 packages from the local monorepo. Order matters for
# npm to resolve workspace peerDeps cleanly: install shared cores first,
# then per-backend cores, then Capacitor wrappers.
npm install --no-save \
  "file:${REPO_ROOT}/packages/dvai-bridge-capacitor" \
  "file:${REPO_ROOT}/packages/dvai-bridge-ios-shared-core" \
  "file:${REPO_ROOT}/packages/dvai-bridge-ios-llama-core" \
  "file:${REPO_ROOT}/packages/dvai-bridge-android-llama-core" \
  "file:${REPO_ROOT}/packages/dvai-bridge-ios-foundation-core" \
  "file:${REPO_ROOT}/packages/dvai-bridge-ios-mlx-core" \
  "file:${REPO_ROOT}/packages/dvai-bridge-android-mediapipe-core" \
  "file:${REPO_ROOT}/packages/dvai-bridge-capacitor-llama" \
  "file:${REPO_ROOT}/packages/dvai-bridge-capacitor-foundation" \
  "file:${REPO_ROOT}/packages/dvai-bridge-capacitor-mlx" \
  "file:${REPO_ROOT}/packages/dvai-bridge-capacitor-mediapipe"

# Add platforms
npx @capacitor/cli add android
if [[ "$(uname)" == "Darwin" ]]; then
  npx @capacitor/cli add ios
fi

# Run cap sync
npx @capacitor/cli sync

# Verify Android Gradle resolves the cores
echo "[verify-cap-sync] running ./gradlew :app:assembleDebug ..."
cd android
chmod +x ./gradlew
./gradlew :app:assembleDebug --no-daemon --stacktrace
cd ..

# iOS verification only on Mac
if [[ "$(uname)" == "Darwin" ]] && [[ -d ios ]]; then
  echo "[verify-cap-sync] running pod install on iOS ..."
  cd ios/App
  pod install
  cd ../..
fi

echo "[verify-cap-sync] OK"
