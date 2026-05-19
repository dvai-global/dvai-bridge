#!/usr/bin/env bash
#
# build-xcframework.sh — produces DVAIBridgeNetBridge.xcframework with
# device (iphoneos), simulator (iphonesimulator), and Mac Catalyst slices,
# ready for consumption by DVAIBridge.iOS.csproj's <NativeReference>.
#
# Outputs:
#   ./DVAIBridgeNetBridge.xcframework/   (3 slices: ios, ios-sim, maccatalyst)
#
# Prerequisites (CI macos-latest runner):
#   - Xcode 16+ (matches Phase 3C's pinned toolchain; Catalyst SDK ships
#     in the bundled macOS SDK)
#   - Swift 5.9+
#   - The Phase 3C iOS umbrella checked out at
#     packages/dvai-bridge-ios (relative to the repo root)
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
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
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
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    IPHONEOS_DEPLOYMENT_TARGET=18.1 \
    -configuration Release \
    | (xcbeautify --quiet || cat)

# Mac Catalyst slice (Task 14). Catalyst is "macOS, variant=Mac Catalyst" —
# Xcode resolves this against the macOS SDK + Catalyst overlay, picking up
# the Phase 3C SwiftPM package's .macCatalyst(.v15_1) platform declaration.
echo "==> xcodebuild archive (maccatalyst)..."
xcodebuild archive \
    -scheme "${SCHEME}" \
    -destination "generic/platform=macOS,variant=Mac Catalyst" \
    -archivePath "${ARCHIVE_DIR}/maccatalyst.xcarchive" \
    -derivedDataPath "${ARCHIVE_DIR}/derived-maccatalyst" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    IPHONEOS_DEPLOYMENT_TARGET=18.1 \
    SUPPORTS_MACCATALYST=YES \
    -configuration Release \
    | (xcbeautify --quiet || cat)

# Locate the .framework inside each archive. SwiftPM emits a .framework
# under Products/usr/local/lib/ when BUILD_LIBRARY_FOR_DISTRIBUTION=YES.
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

# Sanity-check the resulting xcframework lists three AvailableLibraries
# entries with the expected SupportedPlatforms keys.
INFO_PLIST="${OUT}/Info.plist"
if [[ -f "${INFO_PLIST}" ]]; then
    echo "==> Info.plist AvailableLibraries:"
    plutil -extract AvailableLibraries xml1 -o - "${INFO_PLIST}" | \
        grep -E '(SupportedPlatform|LibraryIdentifier)' || true
fi
