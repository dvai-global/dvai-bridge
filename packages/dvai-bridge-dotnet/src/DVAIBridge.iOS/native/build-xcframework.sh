#!/usr/bin/env bash
#
# build-xcframework.sh — produces DVAIBridgeNetBridge.xcframework with
# device (iphoneos) and simulator (iphonesimulator) slices, ready for
# consumption by DVAIBridge.iOS.csproj's <NativeReference>.
#
# Outputs:
#   ./DVAIBridgeNetBridge.xcframework/   (2 slices: ios, ios-sim)
#
# Prerequisites (CI macos-latest runner):
#   - Xcode 26+ (test-dotnet.yml selects /Applications/Xcode_26.3.app;
#     also downloads the Metal Toolchain component which Xcode 26 ships
#     separately and mlx-swift's kernels need)
#   - Swift 6+
#   - The iOS umbrella checked out at packages/dvai-bridge-ios
#     (relative to the repo root)
#   - llama.xcframework + mtmd.xcframework prebuilt under
#     packages/dvai-bridge-android-llama-core/.../build-apple/ via
#     scripts/mac-side-prepare-xcframework.sh
#
# Why no Mac Catalyst slice (v4.2.3): LiteRT-LM (added to the iOS
# umbrella in v4.2.1) transitively links CLiteRTLM.xcframework, which
# ships only ios-arm64 + ios-arm64-simulator — no Catalyst slice at all.
# Restoring Catalyst needs either an upstream Catalyst slice for
# LiteRT-LM, or splitting the iOS umbrella so this .NET binding can opt
# out of LiteRT-LM (planned for v4.3.0). Historically we did ship a
# Catalyst slice (restored in v4.0.1); v4.2.3 pulls it out again.
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

# Mac Catalyst slice — dropped in v4.2.3. LiteRT-LM's CLiteRTLM.xcframework
# has no Catalyst slice (ios-arm64 + ios-arm64-simulator only), and the
# iOS umbrella now transitively links it. Restoring the Catalyst archive
# here means either an upstream Catalyst slice for LiteRT-LM, or splitting
# the iOS umbrella so this binding can opt out of LiteRT-LM (planned for
# v4.3.0). Until then, .NET Mac Catalyst users stay on 4.1.0.

# Locate the .framework inside each archive. SwiftPM emits a .framework
# under Products/usr/local/lib/.
FRAMEWORK_IPHONEOS=$(find "${ARCHIVE_DIR}/iphoneos.xcarchive" -name '*.framework' -type d | head -n 1)
FRAMEWORK_IPHONESIMULATOR=$(find "${ARCHIVE_DIR}/iphonesimulator.xcarchive" -name '*.framework' -type d | head -n 1)

if [[ -z "${FRAMEWORK_IPHONEOS}" || -z "${FRAMEWORK_IPHONESIMULATOR}" ]]; then
    echo "ERROR: failed to locate built .framework in one or more archives." >&2
    echo "  iphoneos: ${FRAMEWORK_IPHONEOS}" >&2
    echo "  iphonesimulator: ${FRAMEWORK_IPHONESIMULATOR}" >&2
    exit 1
fi

echo "==> xcodebuild -create-xcframework (ios + ios-sim)..."
xcodebuild -create-xcframework \
    -framework "${FRAMEWORK_IPHONEOS}" \
    -framework "${FRAMEWORK_IPHONESIMULATOR}" \
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
