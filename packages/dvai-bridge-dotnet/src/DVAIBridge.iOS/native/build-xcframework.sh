#!/usr/bin/env bash
#
# build-xcframework.sh — produces DVAIBridgeNetBridge.xcframework with both
# device (iphoneos) and simulator (iphonesimulator) slices, ready for
# consumption by DVAIBridge.iOS.csproj's <NativeReference>.
#
# Outputs:
#   ./DVAIBridgeNetBridge.xcframework/
#
# Prerequisites (CI macos-latest runner):
#   - Xcode 16+ (matches Phase 3C's pinned toolchain)
#   - Swift 5.9+
#   - The Phase 3C iOS umbrella checked out at
#     packages/dvai-bridge-ios (relative to the repo root)
#
# This is a generated artifact — gitignored. CI runs this before
# `dotnet pack` so the xcframework is bundled into the NuGet.

set -euo pipefail

cd "$(dirname "$0")"

# Workspace + scheme — generated on the fly by SwiftPM's xcodebuild integration.
WORKSPACE="DVAIBridgeNetBridge"
SCHEME="DVAIBridgeNetBridge"
ARCHIVE_DIR="build"
OUT="DVAIBridgeNetBridge.xcframework"

rm -rf "${ARCHIVE_DIR}" "${OUT}"
mkdir -p "${ARCHIVE_DIR}"

echo "==> swift build to populate Package.resolved..."
# Pre-resolve so xcodebuild doesn't fight us about missing deps.
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
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    IPHONEOS_DEPLOYMENT_TARGET=15.1 \
    -configuration Release \
    | xcbeautify --quiet || xcodebuild archive \
        -scheme "${SCHEME}" \
        -destination "generic/platform=iOS" \
        -archivePath "${ARCHIVE_DIR}/iphoneos.xcarchive" \
        -derivedDataPath "${ARCHIVE_DIR}/derived-iphoneos" \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        IPHONEOS_DEPLOYMENT_TARGET=15.1 \
        -configuration Release

echo "==> xcodebuild archive (iphonesimulator)..."
xcodebuild archive \
    -scheme "${SCHEME}" \
    -destination "generic/platform=iOS Simulator" \
    -archivePath "${ARCHIVE_DIR}/iphonesimulator.xcarchive" \
    -derivedDataPath "${ARCHIVE_DIR}/derived-iphonesimulator" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    IPHONEOS_DEPLOYMENT_TARGET=15.1 \
    -configuration Release \
    | xcbeautify --quiet || xcodebuild archive \
        -scheme "${SCHEME}" \
        -destination "generic/platform=iOS Simulator" \
        -archivePath "${ARCHIVE_DIR}/iphonesimulator.xcarchive" \
        -derivedDataPath "${ARCHIVE_DIR}/derived-iphonesimulator" \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        IPHONEOS_DEPLOYMENT_TARGET=15.1 \
        -configuration Release

# Locate the .framework inside each archive. SwiftPM emits a .framework
# under Products/usr/local/lib/ when BUILD_LIBRARY_FOR_DISTRIBUTION=YES.
FRAMEWORK_IPHONEOS=$(find "${ARCHIVE_DIR}/iphoneos.xcarchive" -name '*.framework' -type d | head -n 1)
FRAMEWORK_IPHONESIMULATOR=$(find "${ARCHIVE_DIR}/iphonesimulator.xcarchive" -name '*.framework' -type d | head -n 1)

if [[ -z "${FRAMEWORK_IPHONEOS}" || -z "${FRAMEWORK_IPHONESIMULATOR}" ]]; then
    echo "ERROR: failed to locate built .framework in archives." >&2
    exit 1
fi

echo "==> xcodebuild -create-xcframework..."
xcodebuild -create-xcframework \
    -framework "${FRAMEWORK_IPHONEOS}" \
    -framework "${FRAMEWORK_IPHONESIMULATOR}" \
    -output "${OUT}"

echo "==> Done: ${OUT}"
ls -la "${OUT}"
