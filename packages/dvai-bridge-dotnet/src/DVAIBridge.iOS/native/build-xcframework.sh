#!/usr/bin/env bash
#
# build-xcframework.sh — produces DVAIBridgeNetBridge.xcframework with
# device (iphoneos), simulator (iphonesimulator), and Mac Catalyst
# slices, ready for consumption by DVAIBridge.iOS.csproj's
# <NativeReference>.
#
# Outputs:
#   ./DVAIBridgeNetBridge.xcframework/   (3 slices: ios, ios-sim, maccatalyst)
#
# Prerequisites (CI macos-latest runner):
#   - Xcode 26+ (test-dotnet.yml selects /Applications/Xcode_26.3.app;
#     also downloads the Metal Toolchain component which Xcode 26 ships
#     separately and mlx-swift's kernels need)
#   - Swift 6+
#   - The Phase 3C iOS umbrella checked out at
#     packages/dvai-bridge-ios (relative to the repo root)
#   - llama.xcframework + mtmd.xcframework prebuilt under
#     packages/dvai-bridge-android-llama-core/.../build-apple/ via
#     scripts/mac-side-prepare-xcframework.sh
#
# Why no Mac Catalyst slice (v4.0.0): the upstream llama.xcframework +
# mtmd.xcframework built by mac-side-prepare-xcframework.sh include
# iOS device, iOS simulator, and macOS (regular) slices but NO Mac
# Catalyst variant — adding one means modifying both the upstream
# build-xcframework.sh in llama.cpp's tree AND
# mac-side-prepare-xcframework.sh in our scripts. Deferred to v4.0.1.
# Until then, the DVAIBridge.iOS NuGet ships .NET binding support for
# the `net10.0-ios26.2` TFM only; `net10.0-maccatalyst26.2` consumers
# would link-error against the missing Catalyst slice in the chained
# llama frameworks. See NEXT-RELEASE.md.
#
# Why BUILD_LIBRARY_FOR_DISTRIBUTION=NO: swift-certificates upstream
# bug apple/swift-certificates#254 — `_TinyArray.swift`'s
# extension-init pattern fails to compile under that flag with
# `'self.init' isn't called on all paths`. Apple's maintainer
# confirmed it's "not formally a configuration we support". Switching
# the flag off skips the strict-init checks. For a .NET binding
# xcframework this is fine — the xcframework is consumed by .NET's
# Xamarin runtime via Objective-C interop, not by other Swift
# libraries that would need ABI evolution. Re-enable once
# swift-certificates ships a fix.
#
# This is a generated artifact — gitignored. CI runs this before
# `dotnet pack` so the xcframework is bundled into the NuGet.

set -euo pipefail

cd "$(dirname "$0")"

SCHEME="DVAIBridgeNetBridge"
ARCHIVE_DIR="build"
OUT="DVAIBridgeNetBridge.xcframework"

rm -rf "${ARCHIVE_DIR}" "${OUT}"
mkdir -p "${ARCHIVE_DIR}"

echo "==> swift package resolve to populate Package.resolved..."
swift package resolve

# We use xcodebuild's -archivePath form against the generated SwiftPM project.
# The `-scheme DVAIBridgeNetBridge` matches the SwiftPM library product name.
echo "==> xcodebuild archive (iphoneos)..."
xcodebuild archive \
    -scheme "${SCHEME}" \
    -destination "generic/platform=iOS" \
    -archivePath "${ARCHIVE_DIR}/iphoneos.xcarchive" \
    -derivedDataPath "${ARCHIVE_DIR}/derived-iphoneos" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
    IPHONEOS_DEPLOYMENT_TARGET=18.1 \
    -configuration Release \
    | (xcbeautify --quiet || cat)

echo "==> xcodebuild archive (iphonesimulator)..."
xcodebuild archive \
    -scheme "${SCHEME}" \
    -destination "generic/platform=iOS Simulator" \
    -archivePath "${ARCHIVE_DIR}/iphonesimulator.xcarchive" \
    -derivedDataPath "${ARCHIVE_DIR}/derived-iphonesimulator" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
    IPHONEOS_DEPLOYMENT_TARGET=18.1 \
    -configuration Release \
    | (xcbeautify --quiet || cat)

# Mac Catalyst slice — restored in v4.0.1 now that
# scripts/mac-side-prepare-xcframework.sh builds Catalyst slices into
# the chained llama.xcframework + mtmd.xcframework. Catalyst's
# `-destination "generic/platform=macOS,variant=Mac Catalyst"` builds
# an iOS-shaped binary that runs on macOS; xcodebuild resolves it
# against the macOS SDK with the Catalyst overlay.
echo "==> xcodebuild archive (maccatalyst)..."
xcodebuild archive \
    -scheme "${SCHEME}" \
    -destination "generic/platform=macOS,variant=Mac Catalyst" \
    -archivePath "${ARCHIVE_DIR}/maccatalyst.xcarchive" \
    -derivedDataPath "${ARCHIVE_DIR}/derived-maccatalyst" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
    IPHONEOS_DEPLOYMENT_TARGET=18.1 \
    SUPPORTS_MACCATALYST=YES \
    -configuration Release \
    | (xcbeautify --quiet || cat)

# Locate the .framework inside each archive. SwiftPM emits a .framework
# under Products/usr/local/lib/.
FRAMEWORK_IPHONEOS=$(find "${ARCHIVE_DIR}/iphoneos.xcarchive" -name '*.framework' -type d | head -n 1)
FRAMEWORK_IPHONESIMULATOR=$(find "${ARCHIVE_DIR}/iphonesimulator.xcarchive" -name '*.framework' -type d | head -n 1)
FRAMEWORK_MACCATALYST=$(find "${ARCHIVE_DIR}/maccatalyst.xcarchive" -name '*.framework' -type d | head -n 1)

if [[ -z "${FRAMEWORK_IPHONEOS}" || -z "${FRAMEWORK_IPHONESIMULATOR}" || -z "${FRAMEWORK_MACCATALYST}" ]]; then
    echo "ERROR: failed to locate built .framework in one or more archives." >&2
    echo "  iphoneos: ${FRAMEWORK_IPHONEOS}" >&2
    echo "  iphonesimulator: ${FRAMEWORK_IPHONESIMULATOR}" >&2
    echo "  maccatalyst: ${FRAMEWORK_MACCATALYST}" >&2
    exit 1
fi

echo "==> xcodebuild -create-xcframework (ios + ios-sim + maccatalyst)..."
xcodebuild -create-xcframework \
    -framework "${FRAMEWORK_IPHONEOS}" \
    -framework "${FRAMEWORK_IPHONESIMULATOR}" \
    -framework "${FRAMEWORK_MACCATALYST}" \
    -output "${OUT}"

echo "==> Done: ${OUT}"
ls -la "${OUT}"

# Sanity-check the resulting xcframework lists two AvailableLibraries
# entries with the expected SupportedPlatforms keys.
INFO_PLIST="${OUT}/Info.plist"
if [[ -f "${INFO_PLIST}" ]]; then
    echo "==> Info.plist AvailableLibraries:"
    plutil -extract AvailableLibraries xml1 -o - "${INFO_PLIST}" | \
        grep -E '(SupportedPlatform|LibraryIdentifier)' || true
fi
