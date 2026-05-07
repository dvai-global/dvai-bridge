#!/usr/bin/env bash
# Smoke test for examples/node-llama-cpp/
#
# Runs the example end-to-end and asserts the native backend returns a
# non-empty completion within 60 seconds (excluding model download time).

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
LOG="$DIR/.smoke.log"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

echo "[smoke/node-llama-cpp] starting in $DIR"

# Sanity check: workspace deps are installed (node-llama-cpp + langchain).
if [ ! -d "$DIR/node_modules" ] && [ ! -d "$REPO_ROOT/node_modules/node-llama-cpp" ]; then
  ylw "[warn] node_modules missing — running pnpm install --ignore-scripts"
  ( cd "$REPO_ROOT" && pnpm install --ignore-scripts ) >/dev/null 2>&1 || {
    red "[FAIL] pnpm install failed"
    exit 1
  }
fi

# Ensure the model is cached. The download is part of the example's own
# entry point but pre-running here keeps the 60s budget for inference,
# not download.
echo "[smoke/node-llama-cpp] ensuring model is cached..."
( cd "$DIR" && node scripts/download-model.js ) || {
  red "[FAIL] model download failed"
  exit 1
}

echo "[smoke/node-llama-cpp] running index.js (60s budget)..."

# Run with a 60s wall-clock budget. We capture stdout to inspect the
# completion text afterward.
set +e
( cd "$DIR" && timeout 60 node index.js ) > "$LOG" 2>&1
EXIT=$?
set -e

if [ "$EXIT" -ne 0 ]; then
  red "[FAIL] example exited with status $EXIT"
  echo "----- log -----"
  tail -50 "$LOG" || true
  echo "---------------"
  exit 1
fi

# The example streams tokens to stdout, then prints "[dvai] Local server
# ready at ..." earlier. We assert at least one non-trivial line of
# text appears between the "Local server ready" line and process exit
# (because that's the model's completion).
if ! grep -q "Local server ready" "$LOG"; then
  red "[FAIL] DVAI never reported the local server ready"
  tail -30 "$LOG" || true
  exit 1
fi

# Strip ANSI / dvai log lines and look for any non-empty token output.
COMPLETION="$(grep -v '^\[dvai' "$LOG" | grep -v '^$' | tr -d '\r' | head -20 || true)"
if [ -z "$COMPLETION" ]; then
  red "[FAIL] no completion text in output"
  tail -30 "$LOG" || true
  exit 1
fi

grn "[smoke/node-llama-cpp] PASS — got non-empty completion:"
printf '%s\n' "$COMPLETION" | head -5
