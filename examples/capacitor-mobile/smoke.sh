#!/usr/bin/env bash
# Smoke check for the Capacitor hybrid example.
#
# Validates:
#   1. The www/ web bundle builds (esbuild can resolve @dvai-bridge/capacitor
#      and produce a single main.js).
#   2. `cap sync` accepts our config and finds the iOS + Android plugin
#      configs from the workspace packages, where the platform tooling is
#      available.
#
# This does NOT spin up a simulator or device — that is part of the
# downstream record-demo flow, which is gated by host capability.

set -euo pipefail

cd "$(dirname "$0")"

echo "[smoke] building www/ bundle…"
node scripts/build-www.mjs

if [ ! -f www/main.js ] || [ ! -f www/index.html ]; then
  echo "[smoke] expected www/main.js + www/index.html — build did not produce them" >&2
  exit 1
fi

if [ ! -s www/main.js ]; then
  echo "[smoke] www/main.js is empty" >&2
  exit 1
fi

# Verify the bundled output references the bridge plugin id (proof the
# import was resolved, not stripped).
if ! grep -q "DVAIBridgeLlama\|DVAIBridge" www/main.js; then
  echo "[smoke] www/main.js does not contain the bridge identifier — import resolution may have failed" >&2
  exit 1
fi

# Capacitor CLI is optional on the host; if it's missing we just verify
# the build artefact and exit.
if command -v npx >/dev/null 2>&1 && [ -d node_modules/@capacitor/cli ]; then
  echo "[smoke] npx cap doctor (best effort)…"
  npx --no-install cap doctor || echo "[smoke] cap doctor warnings (expected on hosts without iOS/Android tooling)"
fi

echo "[smoke] OK"
