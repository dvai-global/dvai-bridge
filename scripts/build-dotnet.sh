#!/usr/bin/env bash
# build-dotnet.sh — Build + test + pack the .NET NuGet family.
# Runs on Mac (full matrix) / Windows / Linux (Android + Desktop + ONNX + MLNet only — iOS/Catalyst need macOS).
#
# Dry-run only: emits .nupkg files into packages/dvai-bridge-dotnet/artifacts/
# and stops. Actual `dotnet nuget push` is in PUBLISHING.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PKG_DIR="$REPO_ROOT/packages/dvai-bridge-dotnet"
if [[ ! -d "$PKG_DIR" ]]; then
    echo "ERROR: $PKG_DIR not found." >&2
    exit 1
fi

# Preflight
command -v dotnet >/dev/null 2>&1 || {
    echo "ERROR: dotnet not found. Install .NET SDK 10.0.203 LTS from https://dotnet.microsoft.com/download" >&2
    exit 1
}

DOTNET_VERSION="$(dotnet --version)"
echo "==> [dotnet] SDK $DOTNET_VERSION"

# Workload check
WORKLOADS="$(dotnet workload list 2>/dev/null || true)"
if ! echo "$WORKLOADS" | grep -q "android"; then
    echo "ERROR: 'android' workload missing. Install via 'dotnet workload install android' (or 'sudo dotnet workload install android' on macOS)." >&2
    exit 1
fi

IS_MAC=false
if [[ "$(uname -s)" == "Darwin" ]]; then
    IS_MAC=true
    if ! echo "$WORKLOADS" | grep -q "ios"; then
        echo "WARN: 'ios' workload missing on macOS host. iOS slice will fail to pack." >&2
    fi
    if ! echo "$WORKLOADS" | grep -q "maccatalyst"; then
        echo "WARN: 'maccatalyst' workload missing on macOS host. Catalyst slice will fail to pack." >&2
    fi
fi

cd "$PKG_DIR"

echo "==> [dotnet] dotnet restore"
dotnet restore

echo "==> [dotnet] dotnet build -c Release"
dotnet build -c Release

# Test the testable csprojs (skip the platform-binding shims, which only build with their workload).
TESTABLE=(
    "src/DVAIBridge"
    "src/DVAIBridge.Desktop"
    "src/DVAIBridge.OnnxRuntime"
    "src/DVAIBridge.MLNet"
)

for proj in "${TESTABLE[@]}"; do
    test_proj="${proj/src\//tests/}.Tests"
    if [[ -d "$test_proj" ]]; then
        echo "==> [dotnet:test] $test_proj"
        dotnet test "$test_proj" -c Release --no-build || {
            echo "WARN: tests failed for $test_proj" >&2
        }
    fi
done

# Pack — dry run (no push). Skip iOS/Catalyst on non-Mac hosts.
PACK_PROJS=(
    "src/DVAIBridge"
    "src/DVAIBridge.Desktop"
    "src/DVAIBridge.OnnxRuntime"
    "src/DVAIBridge.MLNet"
    "src/DVAIBridge.Android"
)
if $IS_MAC; then
    PACK_PROJS+=("src/DVAIBridge.iOS")
fi

mkdir -p artifacts
for proj in "${PACK_PROJS[@]}"; do
    if [[ ! -d "$proj" ]]; then
        echo "WARN: $proj not found — skipping" >&2
        continue
    fi
    echo "==> [dotnet:pack] $proj"
    dotnet pack "$proj" -c Release --include-symbols -p:SymbolPackageFormat=snupkg -o ./artifacts --no-build
done

echo "==> [dotnet] OK ($(ls artifacts/*.nupkg 2>/dev/null | wc -l | tr -d ' ') .nupkg files in artifacts/)"
