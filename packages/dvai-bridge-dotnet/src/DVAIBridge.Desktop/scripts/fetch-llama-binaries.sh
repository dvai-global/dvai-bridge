#!/usr/bin/env bash
#
# fetch-llama-binaries.sh — populates src/DVAIBridge.Desktop/runtimes/<rid>/native/
# with llama.cpp release tag b8946 prebuilts for each supported RID. Run this
# before `dotnet pack DVAIBridge.Desktop` on each CI desktop runner.
#
# Coverage (best-effort cross-compile from a single host):
#   - osx-arm64    -> osx-arm64 native (Apple Silicon Mac, Metal-enabled)
#   - osx-x64      -> osx-x64 native (Intel Mac, CPU)
#   - linux-x64    -> linux-x64 (Ubuntu) prebuilt; not cross-compilable from Mac
#                     (need a Linux host or container; CI runs this on ubuntu-22.04)
#   - linux-arm64  -> linux-arm64 (Ubuntu); needs an ARM64 Linux host
#                     (CI uses ubuntu-22.04-arm64 runners)
#   - win-x64      -> win-x64 prebuilt; needs a Windows host or mingw cross-toolchain
#                     (CI runs this on windows-2022)
#   - win-arm64    -> win-arm64 prebuilt; needs a Windows ARM64 host
#                     (CI uses windows-11-arm64 runners)
#
# Realistic fallback policy: each CI runner downloads only the RIDs upstream
# ships pre-built archives for that match the runner's OS family. The pack
# step on each desktop runner produces an OS-specific .nupkg; the publish
# step on macos-latest stitches them together (or, more practically, we
# upload all RID directories as artifacts and the macos packer collects them).
#
# Documented in the spec §3.5.4 — Linux ARM64 specifically may require a
# from-source fallback if upstream's b8946 tag doesn't ship a prebuilt.

set -euo pipefail

TAG="${LLAMA_TAG:-b8946}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
RUNTIMES_DIR="${ROOT}/runtimes"

# Map of RID -> upstream release artifact filename. Some entries fall
# back to "FROM_SOURCE" when upstream hasn't published a prebuilt for
# that RID at the requested tag.
declare -A ARTIFACTS=(
  [win-x64]="llama-${TAG}-bin-win-cpu-x64.zip"
  [win-arm64]="llama-${TAG}-bin-win-cpu-arm64.zip"
  [osx-x64]="llama-${TAG}-bin-macos-x64.zip"
  [osx-arm64]="llama-${TAG}-bin-macos-arm64.zip"
  [linux-x64]="llama-${TAG}-bin-ubuntu-x64.zip"
  [linux-arm64]="FROM_SOURCE"
)

mkdir -p "${RUNTIMES_DIR}"

# Optionally restrict to a single RID via $RID env var (CI per-runner mode).
RID_FILTER="${RID:-}"

for RID in "${!ARTIFACTS[@]}"; do
  if [[ -n "${RID_FILTER}" && "${RID}" != "${RID_FILTER}" ]]; then continue; fi

  ARTIFACT="${ARTIFACTS[$RID]}"
  OUT_DIR="${RUNTIMES_DIR}/${RID}/native"
  mkdir -p "${OUT_DIR}"

  if [[ "${ARTIFACT}" == "FROM_SOURCE" ]]; then
    echo "==> ${RID}: upstream prebuilt unavailable for tag ${TAG} — see scripts/build-llama-from-source.sh (out of scope for this task)" >&2
    echo "    To populate ${OUT_DIR} manually, build llama.cpp at tag ${TAG} with:" >&2
    echo "      cmake -B build -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DGGML_METAL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF" >&2
    echo "      cmake --build build --target llama -j" >&2
    echo "    then copy build/bin/libllama.so + ggml*.so into ${OUT_DIR}" >&2
    continue
  fi

  URL="https://github.com/ggerganov/llama.cpp/releases/download/${TAG}/${ARTIFACT}"
  TMP_ZIP="$(mktemp -t llama-${RID}-XXXXXX.zip)"
  echo "==> Fetching ${URL}"
  if ! curl -fsSL "${URL}" -o "${TMP_ZIP}"; then
    echo "WARN: failed to fetch ${URL} — skipping ${RID}" >&2
    rm -f "${TMP_ZIP}"
    continue
  fi

  echo "==> Extracting native libraries to ${OUT_DIR}"
  # Cross-platform unzip: prefer `unzip` if present; otherwise fall back to
  # `python3 -m zipfile` which ships everywhere.
  if command -v unzip >/dev/null 2>&1; then
    unzip -j -o "${TMP_ZIP}" \
      'build/bin/llama.dll' \
      'build/bin/libllama.dylib' \
      'build/bin/libllama.so' \
      'build/bin/ggml*.dll' \
      'build/bin/libggml*.dylib' \
      'build/bin/libggml*.so' \
      -d "${OUT_DIR}" 2>/dev/null || true
    # Some upstream archives use a different layout — try a permissive sweep.
    unzip -j -o "${TMP_ZIP}" \
      '*/llama.dll' \
      '*/libllama.dylib' \
      '*/libllama.so' \
      '*/ggml*.dll' \
      '*/libggml*.dylib' \
      '*/libggml*.so' \
      -d "${OUT_DIR}" 2>/dev/null || true
  else
    python3 -c "import zipfile, os, sys; z = zipfile.ZipFile(sys.argv[1]); [z.extract(n, sys.argv[2]) for n in z.namelist() if any(p in n for p in ('llama.dll','libllama','ggml'))]" \
      "${TMP_ZIP}" "${OUT_DIR}" || true
  fi

  rm -f "${TMP_ZIP}"

  if [[ -z "$(ls -A "${OUT_DIR}" 2>/dev/null || true)" ]]; then
    echo "WARN: ${OUT_DIR} is empty after extraction — archive layout may have changed" >&2
  else
    echo "==> ${RID} OK: $(ls "${OUT_DIR}" | tr '\n' ' ')"
  fi
done

# If a checksum manifest exists, verify after fetch.
if [[ -f "${HERE}/llama-checksums.txt" ]]; then
  bash "${HERE}/verify-llama-checksums.sh"
fi
