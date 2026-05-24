#!/bin/bash
# scripts/prepare-ios-release.sh
# Forensic preparation script for CocoaPods v4.0.0 release.

set -e

# --- Configuration ---
ROOT_DIR=$(pwd)
IOS_PKG_DIR="$ROOT_DIR/packages/dvai-bridge-ios"
FRAMEWORKS_DIR="$IOS_PKG_DIR/Frameworks"
LLAMA_BUILD_DIR="$ROOT_DIR/packages/dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple"

echo "🔍 Starting forensic iOS release preparation..."

# 1. Clean and Restore
echo "🧹 Cleaning Frameworks directory..."
rm -rf "$FRAMEWORKS_DIR"
mkdir -p "$FRAMEWORKS_DIR"

echo "📦 Copying fresh frameworks from build-apple..."
if [ ! -d "$LLAMA_BUILD_DIR" ]; then
    echo "❌ Error: Build directory not found at $LLAMA_BUILD_DIR"
    exit 1
fi
cp -R "$LLAMA_BUILD_DIR"/*.xcframework "$FRAMEWORKS_DIR/"

# 2. Forensic Pruning
echo "✂️ Pruning non-iOS slices..."
for xcframework in "$FRAMEWORKS_DIR"/*.xcframework; do
    echo "  Processing $(basename "$xcframework")..."
    
    # Remove everything except iOS and Simulator slices
    find "$xcframework" -maxdepth 1 -not -name 'ios-*' -not -name 'Info.plist' -not -name "$(basename "$xcframework")" -exec rm -rf {} +
    
    # Remove dSYMs (CocoaPods often chokes on them in monorepos)
    find "$xcframework" -name "dSYMs" -exec rm -rf {} +
done

# 3. Validation & Info.plist Sanitization
# We will regenerate the Info.plist to be 100% sure it matches the disk
generate_plist() {
    local name=$1
    local framework_file="$FRAMEWORKS_DIR/$name.xcframework"
    local plist_path="$framework_file/Info.plist"

    echo "📝 Regenerating Info.plist for $name.xcframework..."
    
    cat <<EOF > "$plist_path"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>$name.framework/$name</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>$name.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
		</dict>
		<dict>
			<key>BinaryPath</key>
			<string>$name.framework/$name</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64_x86_64-simulator</string>
			<key>LibraryPath</key>
			<string>$name.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
			<key>SupportedPlatformVariant</key>
			<string>simulator</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF
}

generate_plist "llama"
generate_plist "mtmd"

# 4. Final Linkage Audit
echo "🔬 Auditing binary linkage..."
check_linkage() {
    local binary_path=$1
    local type=$(otool -hv "$binary_path" | grep MH_ | awk '{print $5}' | head -n 1)
    echo "  $binary_path -> $type"
    if [[ "$type" != "DYLIB" ]]; then
        echo "⚠️  WARNING: $binary_path is $type (not DYLIB). This might cause 'Mixed' errors if others are DYLIB."
    fi
}

find "$FRAMEWORKS_DIR" -name "llama" -type f | while read -r bin; do check_linkage "$bin"; done
find "$FRAMEWORKS_DIR" -name "mtmd" -type f | while read -r bin; do check_linkage "$bin"; done

echo "✅ Forensic preparation complete."

# 5. Package for CocoaPods (Lightweight payload)
echo "📦 Packaging for CocoaPods..."
# Derive version from root package.json so this script doesn't need
# yearly hand-editing on every release. node -p falls back to manual
# override via VERSION=4.0.1 bash scripts/prepare-ios-release.sh.
VERSION="${VERSION:-$(node -p "require('$ROOT_DIR/package.json').version")}"
ZIP_NAME="DVAIBridge-v${VERSION}.zip"
rm -f "$ZIP_NAME"

PKG_DIR="cocoapods_temp"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/packages"

# Copy only what is needed for the Pod
cp -R packages/dvai-bridge-ios "$PKG_DIR/packages/"
cp -R packages/dvai-bridge-ios-shared-core "$PKG_DIR/packages/"
cp -R packages/dvai-bridge-ios-llama-core "$PKG_DIR/packages/"

# Pre-stage Sources/_external so the published podspec needs no prepare_command.
# CocoaPods Trunk has been rejecting specs with prepare_command (500, no body);
# baking the file layout into the zip side-steps that entirely.
echo "PRE-STAGE: copying sibling-package sources into Sources/_external/"
EXT="$PKG_DIR/packages/dvai-bridge-ios/Sources/_external"
rm -rf "$EXT"
mkdir -p "$EXT"
cp -R "$PKG_DIR/packages/dvai-bridge-ios-shared-core/ios/Sources/DVAISharedCore" "$EXT/"
cp -R "$PKG_DIR/packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore" "$EXT/"
cp -R "$PKG_DIR/packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC" "$EXT/"
cp DVAIBridge.podspec "$PKG_DIR/"
cp LICENSE "$PKG_DIR/"
cp README.md "$PKG_DIR/"

# Zip it up
(cd "$PKG_DIR" && zip -rq "../$ZIP_NAME" . -x "*/.build/*" -x "*/.swiftpm/*" -x "*/build/*" -x "*/node_modules/*" -x "*/.git/*" -x "*/.gradle/*" -x "*/DerivedData/*" -x "*.DS_Store" -x "*.xcuserstate" -x "*/xcuserdata/*")

rm -rf "$PKG_DIR"
echo "✅ Created $ZIP_NAME."
echo "🚀 Next steps:"
echo "  1. Upload $ZIP_NAME to GitHub Release v4.0.0"
echo "  2. I will update the podspec to point to this ZIP"
echo "  3. pod trunk push DVAIBridge.podspec --allow-warnings"
