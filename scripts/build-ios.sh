#!/usr/bin/env bash
# build-ios.sh — Build + test the iOS slice. Mac-only.
# Wraps the existing mac-side-*.sh helpers behind a single command.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Host check
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: build-ios.sh requires macOS (Xcode + iOS Simulator)." >&2
    echo "       From a Windows host, use scripts/mac-build.ps1 to drive an SSH-attached Mac." >&2
    exit 1
fi

# Preflight
command -v xcodebuild >/dev/null 2>&1 || {
    echo "ERROR: xcodebuild not found. Install Xcode from the Mac App Store and run xcode-select --install." >&2
    exit 1
}
command -v pod >/dev/null 2>&1 || {
    echo "ERROR: CocoaPods not found. Install via 'sudo gem install cocoapods' or 'brew install cocoapods'." >&2
    exit 1
}

# Delegate to the mac-side helpers (which contain all the actual logic).
echo "==> [ios] mac-side-prepare-xcframework.sh"
bash scripts/mac-side-prepare-xcframework.sh

echo "==> [ios] mac-side-build.sh"
bash scripts/mac-side-build.sh

echo "==> [ios] mac-side-test.sh"
bash scripts/mac-side-test.sh

echo "==> [ios] OK"
