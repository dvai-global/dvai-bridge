#!/usr/bin/env bash
# Smoke test for the DVAIBridge MAUI sample.
#
# What it does (host-conditional):
#   - Always: `dotnet build -f net10.0-android36.0` (works on any host with
#     the Android workload + JDK + Android SDK).
#   - Mac only: also builds net10.0-ios26.4 and net10.0-maccatalyst26.4.
#
# Smoke verifies that every TFM the host CAN build builds clean.
# Returns 0 on success / 1 on any failure.

set -euo pipefail

cd "$(dirname "$0")"

# Detect host.
UNAME="$(uname 2>/dev/null || echo Windows)"
IS_MAC=0
if [[ "$UNAME" == "Darwin" ]]; then
  IS_MAC=1
fi

# Always: Android build.
echo "==> dotnet build -f net10.0-android36.0"
dotnet build -f net10.0-android36.0 -c Release --nologo

if [[ "$IS_MAC" == "1" ]]; then
  echo "==> dotnet build -f net10.0-ios26.4 (Mac host detected)"
  dotnet build -f net10.0-ios26.4 -c Release --nologo
  echo "==> dotnet build -f net10.0-maccatalyst26.4 (Mac host detected)"
  dotnet build -f net10.0-maccatalyst26.4 -c Release --nologo
else
  echo "==> Skipping iOS / Mac Catalyst legs (not on a Mac host)."
fi

echo "==> dotnet-maui smoke OK"
