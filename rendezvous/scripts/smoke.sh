#!/usr/bin/env bash
# smoke.sh — start server, hit /health, exit 0 if responsive.
#
# Doesn't run a full pair flow (that's the job of vitest's tests/);
# this proves the binary builds + binds + serves the health endpoint.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# Preflight
command -v node >/dev/null 2>&1 || { echo "ERROR: node not found" >&2; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "ERROR: npm not found" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found" >&2; exit 1; }

PORT="${PORT:-18080}"   # use a non-default port to avoid clashing with a running dev server

echo "[smoke/rendezvous] building..."
if [[ ! -d node_modules ]]; then
    npm install --silent
fi
npm run build --silent

echo "[smoke/rendezvous] starting server on :${PORT}..."
PORT="$PORT" node dist/server.js >/tmp/rendezvous-smoke.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

# Wait up to 10 seconds for /health
for i in $(seq 1 20); do
    if curl --silent --max-time 1 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

RESPONSE="$(curl --silent --max-time 2 "http://127.0.0.1:${PORT}/health" || true)"
if [[ -z "$RESPONSE" ]]; then
    echo "[smoke/rendezvous] FAIL — server did not respond" >&2
    cat /tmp/rendezvous-smoke.log >&2
    exit 1
fi

echo "[smoke/rendezvous] /health → $RESPONSE"

if echo "$RESPONSE" | grep -q '"status":"ok"'; then
    echo "[smoke/rendezvous] PASS"
    exit 0
else
    echo "[smoke/rendezvous] FAIL — unexpected response shape" >&2
    exit 1
fi
