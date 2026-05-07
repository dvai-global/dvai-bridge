#!/usr/bin/env bash
# Smoke check for the Flutter example.
#
# Validates:
#   1. `flutter pub get` resolves the path-dep against
#      `packages/dvai-bridge-flutter/`.
#   2. The plugin's Pigeon stubs are up to date (`dart run pigeon`).
#   3. `flutter analyze` passes — proves `lib/main.dart` types against the
#      workspace plugin's API.
#   4. `flutter test` passes (smoke-level widget tests).
#
# Real iOS / Android builds happen on a host with the matching toolchain;
# this smoke runs anywhere Flutter is installed.

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v flutter >/dev/null 2>&1; then
  echo "[smoke] flutter not on PATH" >&2
  exit 1
fi

# 1. Pigeon regen on the workspace plugin (cheap; no-op when up to date).
echo "[smoke] regenerating Pigeon bindings on the dvai_bridge plugin…"
pushd ../../packages/dvai-bridge-flutter >/dev/null
flutter pub get
dart run pigeon --input pigeons/messages.dart
popd >/dev/null

# 2. Resolve our example's deps via path-dep.
echo "[smoke] flutter pub get…"
flutter pub get

# 3. Static analysis.
echo "[smoke] flutter analyze…"
flutter analyze

# 4. Tests.
echo "[smoke] flutter test…"
flutter test

echo "[smoke] OK"
