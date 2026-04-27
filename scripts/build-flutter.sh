#!/usr/bin/env bash
# build-flutter.sh — Build + test the Flutter plugin (dvai_bridge).
# Runs on any host with Flutter SDK ≥ 3.39 installed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PKG_DIR="$REPO_ROOT/packages/dvai-bridge-flutter"
if [[ ! -d "$PKG_DIR" ]]; then
    echo "ERROR: $PKG_DIR not found." >&2
    exit 1
fi

# Preflight
command -v flutter >/dev/null 2>&1 || {
    echo "ERROR: flutter not found. Install via https://docs.flutter.dev/get-started/install (or Android Studio's Flutter plugin)." >&2
    exit 1
}
command -v dart >/dev/null 2>&1 || {
    echo "ERROR: dart not found (should ship with flutter)." >&2
    exit 1
}

cd "$PKG_DIR"

echo "==> [flutter] flutter pub get"
flutter pub get

echo "==> [flutter] dart run pigeon (regen platform channels)"
dart run pigeon --input pigeons/messages.dart || {
    echo "WARN: pigeon regen failed — check pigeons/messages.dart exists." >&2
}

echo "==> [flutter] flutter analyze"
flutter analyze

echo "==> [flutter] flutter test"
flutter test

echo "==> [flutter] flutter pub publish --dry-run (validates package layout)"
flutter pub publish --dry-run

echo "==> [flutter] OK"
