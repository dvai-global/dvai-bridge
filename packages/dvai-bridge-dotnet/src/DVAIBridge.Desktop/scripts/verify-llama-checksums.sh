#!/usr/bin/env bash
#
# verify-llama-checksums.sh — validates SHA256 of every file under
# runtimes/ against the manifest at llama-checksums.txt. Run after fetch
# and before pack to catch supply-chain drift.
#
# Manifest format (one line per file, blank lines + # comments tolerated):
#   <hex-sha256>  <relative-path-from-runtimes/>

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
RUNTIMES_DIR="${ROOT}/runtimes"
MANIFEST="${HERE}/llama-checksums.txt"

if [[ ! -f "${MANIFEST}" ]]; then
  echo "WARN: ${MANIFEST} missing — skipping checksum verification (first-time setup)" >&2
  exit 0
fi

if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD="shasum -a 256"
else
  echo "ERROR: neither sha256sum nor shasum is on PATH" >&2
  exit 2
fi

EXIT=0
while IFS= read -r line; do
  case "${line}" in
    ''|'#'*) continue ;;
  esac
  expected="$(echo "${line}" | awk '{print $1}')"
  rel="$(echo "${line}" | awk '{print $2}')"
  full="${RUNTIMES_DIR}/${rel}"
  if [[ ! -f "${full}" ]]; then
    echo "MISSING: ${rel}" >&2
    EXIT=1
    continue
  fi
  actual="$(${HASH_CMD} "${full}" | awk '{print $1}')"
  if [[ "${expected}" != "${actual}" ]]; then
    echo "DRIFT: ${rel}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    EXIT=1
  fi
done < "${MANIFEST}"

if [[ "${EXIT}" -ne 0 ]]; then
  echo "Checksum verification failed." >&2
fi
exit "${EXIT}"
