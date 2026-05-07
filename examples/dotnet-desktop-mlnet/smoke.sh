#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "==> dotnet build -c Release"
dotnet build -c Release --nologo

echo "==> Headless smoke run"
DVAI_HEADLESS=1 dotnet run -c Release --no-build

echo "==> dotnet-desktop-mlnet smoke OK"
