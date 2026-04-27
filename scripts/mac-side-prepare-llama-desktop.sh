#!/usr/bin/env bash
# scripts/mac-side-prepare-llama-desktop.sh
#
# Builds llama.cpp at tag b8946 for desktop RIDs and stages the resulting
# shared libraries under packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/runtimes/.
#
# Reality check: a Mac host can natively cross-compile to:
#   - osx-arm64 (native, Metal-enabled) ✓
#   - osx-x64 (via -DCMAKE_OSX_ARCHITECTURES=x86_64) ✓
# But cannot reliably produce binaries for:
#   - linux-x64 / linux-arm64 — need a Linux toolchain (use Docker or a Linux runner)
#   - win-x64 / win-arm64 — need a Windows toolchain or mingw cross-compiler
#
# This script handles the two macOS RIDs natively. For non-Mac RIDs, run the
# matching workflow on the dedicated host:
#   - Linux: bash packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/scripts/fetch-llama-binaries.sh
#     (uses upstream's prebuilt linux-x64 release artifact)
#   - Windows: bash packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/scripts/fetch-llama-binaries.sh
#     (uses upstream's prebuilt win-x64 release artifact)
#
# Run on Mac: bash scripts/mac-side-prepare-llama-desktop.sh
#
# Honors:
#   FORCE=1     -> rebuild even if outputs exist
#   LLAMA_TAG   -> override default release tag (default: b8946)

set -euo pipefail

TAG="${LLAMA_TAG:-b8946}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
DEST_BASE="${REPO_ROOT}/packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/runtimes"
WORK="$(mktemp -d -t llama-desktop-XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

if ! command -v cmake >/dev/null 2>&1; then
  echo "ERROR: cmake required (brew install cmake)" >&2
  exit 2
fi

echo "==> Cloning llama.cpp ${TAG}..."
cd "${WORK}"
git clone --depth 1 --branch "${TAG}" https://github.com/ggerganov/llama.cpp.git
cd llama.cpp

build_for_arch() {
  local rid="$1"
  local arch="$2"
  local cmake_arch="$3"
  local out="${DEST_BASE}/${rid}/native"
  mkdir -p "${out}"

  if [[ -z "${FORCE:-}" && -f "${out}/libllama.dylib" ]]; then
    echo "==> ${rid}: existing libllama.dylib found — skip (FORCE=1 to rebuild)"
    return 0
  fi

  echo "==> Building ${rid} (${arch})..."
  rm -rf "build-${arch}"
  cmake -B "build-${arch}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="${cmake_arch}" \
    -DGGML_METAL=$([ "${arch}" = "arm64" ] && echo ON || echo OFF) \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DBUILD_SHARED_LIBS=ON
  cmake --build "build-${arch}" --target llama -j

  # Collect libllama + ggml siblings.
  for f in "build-${arch}/bin/libllama.dylib" "build-${arch}"/bin/libggml*.dylib; do
    if [[ -f "${f}" ]]; then
      cp -f "${f}" "${out}/"
    fi
  done

  echo "==> ${rid}: $(ls "${out}" | tr '\n' ' ')"
}

build_for_arch osx-arm64 arm64 arm64
build_for_arch osx-x64 x86_64 x86_64

echo ""
echo "==> Mac-side build done."
echo "    Outputs: ${DEST_BASE}/osx-{arm64,x64}/native/"
echo ""
echo "    For other RIDs (linux-{x64,arm64}, win-{x64,arm64}), use the"
echo "    fetch-llama-binaries.sh script on the matching host:"
echo "      bash packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/scripts/fetch-llama-binaries.sh"
