#!/usr/bin/env bash
# scripts/mac-side-build-examples.sh — Run on Mac (typically via
# `ssh mac`). Builds every iOS example app in examples/ios-* in one
# session so we don't pay per-example SSH boot cost.
#
# Per design spec §5 Q7: Mac builds are batched, not synchronous.
#
# Usage (on Mac):
#   bash scripts/mac-side-build-examples.sh [build|test]
#
# Usage (driving from another host):
#   ssh mac 'cd ~/Developer/dvai-bridge && git pull && bash scripts/mac-side-build-examples.sh build'
#
# `build`   — xcodebuild build (default; cheap, doesn't run tests).
# `test`    — xcodebuild test (runs the example's smoke tests; slower).

set -euo pipefail

MODE="${1:-build}"
case "$MODE" in
  build|test) ;;
  *) echo "Usage: $0 [build|test]" >&2; exit 2 ;;
esac

DEST="${IOS_DEST:-platform=iOS Simulator,name=iPhone 16,OS=18.5}"

EXAMPLES=(
  "ios-llama:IOSLlamaApp"
  "ios-foundation:IOSFoundationApp"
  "ios-coreml:IOSCoreMLApp"
  "ios-mlx:IOSMLXApp"
)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "[mac-side-build-examples] Mode: $MODE  Dest: $DEST"
echo "[mac-side-build-examples] Repo: $REPO_ROOT"
echo

PASS=()
FAIL=()
for entry in "${EXAMPLES[@]}"; do
  name="${entry%%:*}"
  scheme="${entry##*:}"
  dir="$REPO_ROOT/examples/$name"
  if [[ ! -f "$dir/Package.swift" ]]; then
    echo "[mac-side-build-examples] SKIP $name (no Package.swift at $dir)"
    continue
  fi
  echo
  echo "==== $name ($scheme) — $MODE ===="
  if (cd "$dir" && xcodebuild "$MODE" \
        -scheme "$scheme" \
        -destination "$DEST" \
        -configuration Debug \
        2>&1 | tail -200); then
    echo "[mac-side-build-examples] PASS $name"
    PASS+=("$name")
  else
    echo "[mac-side-build-examples] FAIL $name"
    FAIL+=("$name")
  fi
done

echo
echo "==== Summary ===="
echo "PASS: ${PASS[*]:-<none>}"
echo "FAIL: ${FAIL[*]:-<none>}"
if [[ ${#FAIL[@]} -gt 0 ]]; then
  exit 1
fi
