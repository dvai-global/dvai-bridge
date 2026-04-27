#!/usr/bin/env bash
# build-web.sh — Build + test the JS family (core, react, vanilla, capacitor*).
# Runs on any host (Mac / Linux / Windows-bash / WSL).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Preflight
command -v pnpm >/dev/null 2>&1 || {
    echo "ERROR: pnpm not found. Install via 'npm install -g pnpm' or follow https://pnpm.io/installation" >&2
    exit 1
}
command -v node >/dev/null 2>&1 || {
    echo "ERROR: node not found. Install Node.js 22+ from https://nodejs.org/" >&2
    exit 1
}

echo "==> [web] pnpm install"
pnpm install --frozen-lockfile

echo "==> [web] pnpm -r run build"
pnpm -r run build

echo "==> [web] pnpm test"
pnpm test

echo "==> [web] OK"
