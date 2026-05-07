#!/usr/bin/env bash
# Smoke test for examples/web-vanilla-cdn/
#
# This example is intentionally non-buildable: the smoke test exercises
# only what we can verify without launching a browser:
#   1. index.html parses (well-formed XML/HTML).
#   2. The local script reference resolves on disk.
#   3. The documented jsDelivr URL is reachable (soft check; warns on 404
#      because the package may not be public yet).

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

echo "[smoke/web-vanilla-cdn] starting in $DIR"

# 1. index.html parses.
if [ ! -f "$DIR/index.html" ]; then
  red "[FAIL] index.html missing"
  exit 1
fi

# Cheap parse check: the file must contain an opening <html>, an
# <body>, and a closing </html>. We don't need a full HTML5 parser
# for this smoke; if the file becomes garbled the basic structure
# tags would also vanish.
if ! grep -q '<html' "$DIR/index.html" \
   || ! grep -q '<body' "$DIR/index.html" \
   || ! grep -q '</html>' "$DIR/index.html"; then
  red "[FAIL] index.html does not look like a complete HTML document"
  exit 1
fi
grn "[ok] index.html structure"

# 2. The local script reference resolves on disk.
LOCAL_SCRIPT="$REPO_ROOT/packages/dvai-bridge-vanilla/dist/index.global.js"
if [ ! -f "$LOCAL_SCRIPT" ]; then
  red "[FAIL] local script not found: $LOCAL_SCRIPT"
  red "       run \`pnpm --filter @dvai-bridge/vanilla build\` first"
  exit 1
fi
grn "[ok] local script resolves: $LOCAL_SCRIPT"

if [ ! -f "$DIR/app.js" ]; then
  red "[FAIL] app.js missing"
  exit 1
fi
grn "[ok] app.js present"

# 3. jsDelivr soft-check — never fails the smoke; just informs.
JSDELIVR_URL="https://cdn.jsdelivr.net/npm/@dvai-bridge/vanilla@latest/dist/index.global.js"
if command -v curl >/dev/null 2>&1; then
  STATUS="$(curl -s -o /dev/null -w '%{http_code}' -L "$JSDELIVR_URL" || echo "000")"
  case "$STATUS" in
    200)
      grn "[ok] jsDelivr URL reachable ($STATUS): $JSDELIVR_URL"
      ;;
    404)
      ylw "[warn] jsDelivr URL returned 404 — package not yet public on npm."
      ylw "       Local file fallback is in use; example still runs."
      ;;
    *)
      ylw "[warn] jsDelivr URL status $STATUS — network may be flaky."
      ;;
  esac
else
  ylw "[warn] curl not on PATH; skipping jsDelivr reachability check"
fi

grn "[smoke/web-vanilla-cdn] PASS"
