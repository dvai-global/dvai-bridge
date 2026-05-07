#!/usr/bin/env bash
# Smoke test: build + headless run.
# Returns 0 if the project builds and the facade resolves the desktop
# slice (model file may be missing — we check the WIRING, not weights).

set -euo pipefail

cd "$(dirname "$0")"

echo "==> dotnet build -c Release"
dotnet build -c Release --nologo

echo "==> Headless smoke run"
DVAI_HEADLESS=1 dotnet run -c Release --no-build

echo "==> dotnet-desktop-llama smoke OK"
