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
echo "🚀 Next steps:"
echo "  1. git add packages/dvai-bridge-ios/Frameworks"
echo "  2. git commit -m 'chore: forensic cleanup of xcframeworks'"
echo "  3. git push origin main"
echo "  4. (I will update the tag)"
echo "  5. pod cache clean DVAIBridge"
echo "  6. pod trunk push DVAIBridge.podspec --allow-warnings"
