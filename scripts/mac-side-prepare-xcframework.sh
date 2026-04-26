#!/usr/bin/env bash
# scripts/mac-side-prepare-xcframework.sh
#
# Builds llama.xcframework AND mtmd.xcframework from the pinned llama.cpp
# submodule. The xcframeworks are gitignored; rebuild whenever the
# llama.cpp submodule SHA changes.
#
# Why we need this: upstream llama.cpp removed Package.swift after tag
# b4823 (March 2025) in favor of build-xcframework.sh. Our outer
# packages/dvai-bridge-capacitor-llama/ios/Package.swift declares
# .binaryTarget entries pointing at the xcframework paths produced here.
#
# llama.xcframework is built by upstream's build-xcframework.sh, which
# defaults LLAMA_BUILD_TOOLS=OFF and only packages the `llama` target.
# mtmd lives under tools/mtmd, so it isn't in that xcframework.
#
# We build mtmd in a separate post-step:
#   1. Reconfigure each existing build-* dir with -DLLAMA_BUILD_TOOLS=ON
#      so the `mtmd` CMake target is added.
#   2. cmake --build --target mtmd to compile only the mtmd library
#      (avoids pulling in CLI executables that don't cross-compile).
#   3. Package per-platform libmtmd.a into mtmd.framework with a
#      modulemap re-exporting mtmd.h / mtmd-helper.h.
#   4. xcodebuild -create-xcframework to bundle into mtmd.xcframework.
#
# Run on Mac: bash scripts/mac-side-prepare-xcframework.sh
#
# Honors:
#   FORCE=1   -> rebuild even if both xcframeworks already exist.
set -euo pipefail

LLAMA_DIR="packages/dvai-bridge-capacitor-llama/native/llama.cpp"
LLAMA_XCF_PATH="$LLAMA_DIR/build-apple/llama.xcframework"
MTMD_XCF_PATH="$LLAMA_DIR/build-apple/mtmd.xcframework"

if [ -d "$LLAMA_XCF_PATH" ] && [ -d "$MTMD_XCF_PATH" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "[prepare-xcframework] $LLAMA_XCF_PATH and $MTMD_XCF_PATH already exist; skipping rebuild."
    echo "[prepare-xcframework] Set FORCE=1 to rebuild from scratch."
    exit 0
fi

# Make sure homebrew tools (cmake) are on PATH for non-interactive shells.
if [ -x /opt/homebrew/bin/cmake ] && ! command -v cmake >/dev/null 2>&1; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "[prepare-xcframework] cmake not found on PATH. Install via 'brew install cmake'." >&2
    exit 1
fi

cd "$LLAMA_DIR"

# OS-version floors must match build-xcframework.sh (the script's first
# block of variable assignments). Keep these in sync on submodule bumps.
IOS_MIN_OS_VERSION=16.4
MACOS_MIN_OS_VERSION=13.3
VISIONOS_MIN_OS_VERSION=1.0
TVOS_MIN_OS_VERSION=16.4

# Step 1: build llama.xcframework via upstream's script.
if [ ! -d "build-apple/llama.xcframework" ] || [ "${FORCE:-0}" = "1" ]; then
    echo "[prepare-xcframework] Running build-xcframework.sh (this takes ~5-15 min)..."
    bash build-xcframework.sh
else
    echo "[prepare-xcframework] llama.xcframework exists; skipping upstream build."
fi
echo "[prepare-xcframework] llama.xcframework -> $LLAMA_DIR/build-apple/llama.xcframework"

# Step 2: build mtmd as a static library in each per-platform build dir.
#
# Each entry: "<build-dir>:<platform>:<sdk>:<archs>:<min-version>:<simulator?>"
# "simulator" controls install_name + min-version flag and matches how
# upstream's combine_static_libraries() chooses its variants.
# Only iOS + macOS are needed — Package.swift declares
# `platforms: [.iOS(.v14), .macOS(.v12)]`, so visionOS and tvOS slices
# would be dead weight. They ALSO break the LLAMA_BUILD_TOOLS=ON
# reconfigure path because tools/* CMakeLists.txt declare MACOSX_BUNDLE
# executable targets without BUNDLE DESTINATION, which CMake rejects
# on visionOS/tvOS. Skipping those slices avoids the configure failure
# entirely and gives us a smaller xcframework.
#
# (The upstream build-xcframework.sh in Step 1 still produces all
# slices for llama.xcframework; we only constrain the mtmd pass here.)
PLATFORMS=(
    "build-ios-sim:ios:iphonesimulator:arm64;x86_64:${IOS_MIN_OS_VERSION}:true"
    "build-ios-device:ios:iphoneos:arm64:${IOS_MIN_OS_VERSION}:false"
    "build-macos:macos:macosx:arm64;x86_64:${MACOS_MIN_OS_VERSION}:false"
)

# release_dir per platform mirrors what upstream's script passes to
# combine_static_libraries; libmtmd.a will land under that subdir.
release_dir_for() {
    local sdk="$1"
    case "$sdk" in
        iphonesimulator)  echo "Release-iphonesimulator" ;;
        iphoneos)         echo "Release-iphoneos" ;;
        macosx)           echo "Release" ;;
        xros)             echo "Release-xros" ;;
        xrsimulator)      echo "Release-xrsimulator" ;;
        appletvsimulator) echo "Release-appletvsimulator" ;;
        appletvos)        echo "Release-appletvos" ;;
        *) echo "Release" ;;
    esac
}

# Reconfigure with LLAMA_BUILD_TOOLS=ON. The mtmd target itself only links
# `ggml` and `llama` (see tools/mtmd/CMakeLists.txt), so building just
# `--target mtmd` doesn't require any of the CLI executables to be
# buildable for the platform.
echo "[prepare-xcframework] Configuring mtmd target in each build-* directory..."
for entry in "${PLATFORMS[@]}"; do
    IFS=':' read -r build_dir platform sdk archs min_ver is_sim <<< "$entry"
    if [ ! -f "$build_dir/CMakeCache.txt" ]; then
        echo "[prepare-xcframework] WARN: $build_dir not configured by build-xcframework.sh, skipping mtmd build"
        continue
    fi
    echo "[prepare-xcframework]   reconfigure: $build_dir (LLAMA_BUILD_TOOLS=ON)"
    cmake -B "$build_dir" \
        -DLLAMA_BUILD_TOOLS=ON \
        -DLLAMA_BUILD_COMMON=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_SERVER=OFF \
        > /dev/null
    echo "[prepare-xcframework]   build mtmd target: $build_dir"
    cmake --build "$build_dir" --config Release --target mtmd -- -quiet
done

# Step 3: package libmtmd.a into per-platform mtmd.framework.
package_mtmd_framework() {
    local build_dir="$1"
    local platform="$2"
    local sdk="$3"
    local archs="$4"
    local min_ver="$5"
    local is_sim="$6"
    local base_dir
    base_dir="$(pwd)"
    local release_dir
    release_dir="$(release_dir_for "$sdk")"
    local framework_name="mtmd"

    local libmtmd="${build_dir}/tools/mtmd/${release_dir}/libmtmd.a"
    if [ ! -f "$libmtmd" ]; then
        echo "[prepare-xcframework] WARN: $libmtmd not found, skipping framework packaging"
        return 1
    fi

    # Lay out framework dir.
    local fw_root="${build_dir}/framework/${framework_name}.framework"
    rm -rf "$fw_root"
    if [ "$platform" = "macos" ]; then
        mkdir -p "${fw_root}/Versions/A/Headers"
        mkdir -p "${fw_root}/Versions/A/Modules"
        mkdir -p "${fw_root}/Versions/A/Resources"
        ln -sf A "${fw_root}/Versions/Current"
        ln -sf Versions/Current/Headers "${fw_root}/Headers"
        ln -sf Versions/Current/Modules "${fw_root}/Modules"
        ln -sf Versions/Current/Resources "${fw_root}/Resources"
        ln -sf "Versions/Current/${framework_name}" "${fw_root}/${framework_name}"
        local header_path="${fw_root}/Versions/A/Headers"
        local module_path="${fw_root}/Versions/A/Modules"
        local plist_path="${fw_root}/Versions/A/Resources/Info.plist"
        local output_lib="${fw_root}/Versions/A/${framework_name}"
        local install_name="@rpath/${framework_name}.framework/Versions/Current/${framework_name}"
    else
        mkdir -p "${fw_root}/Headers"
        mkdir -p "${fw_root}/Modules"
        local header_path="${fw_root}/Headers"
        local module_path="${fw_root}/Modules"
        local plist_path="${fw_root}/Info.plist"
        local output_lib="${fw_root}/${framework_name}"
        local install_name="@rpath/${framework_name}.framework/${framework_name}"
    fi

    # Public mtmd headers. mtmd.h transitively #include <ggml.h> and
    # <llama.h>, which are re-exported by llama.framework -- the consuming
    # bridge code must import both. The modulemap below does NOT declare
    # those headers (they're in the sibling module), so the consumer's
    # @import resolves them via the llama framework module.
    cp tools/mtmd/mtmd.h        "$header_path/"
    cp tools/mtmd/mtmd-helper.h "$header_path/"

    cat > "${module_path}/module.modulemap" <<'EOF'
framework module mtmd {
    header "mtmd.h"
    header "mtmd-helper.h"

    link "c++"

    export *
}
EOF

    # Info.plist (mirror of upstream's setup_framework_structure).
    local platform_name="" sdk_name="" supported_platform="" device_family=""
    case "$platform" in
        ios)
            platform_name="iphoneos"; sdk_name="iphoneos${min_ver}"; supported_platform="iPhoneOS"
            device_family='    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>'
            ;;
        macos)
            platform_name="macosx"; sdk_name="macosx${min_ver}"; supported_platform="MacOSX"
            ;;
        visionos)
            platform_name="xros"; sdk_name="xros${min_ver}"; supported_platform="XRPlatform"
            ;;
        tvos)
            platform_name="appletvos"; sdk_name="appletvos${min_ver}"; supported_platform="AppleTVOS"
            device_family='    <key>UIDeviceFamily</key>
    <array>
        <integer>3</integer>
    </array>'
            ;;
    esac
    cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${framework_name}</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.${framework_name}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${framework_name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${min_ver}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${supported_platform}</string>
    </array>${device_family}
    <key>DTPlatformName</key>
    <string>${platform_name}</string>
    <key>DTSDKName</key>
    <string>${sdk_name}</string>
</dict>
</plist>
EOF

    # Build a dynamic library from libmtmd.a (mirror of upstream's
    # combine_static_libraries). mtmd's symbols + transitive ggml/llama
    # references are resolved at link time via the consumer's link of
    # llama.framework, so we only force-load libmtmd.a here.
    local temp_dir="${build_dir}/mtmd_pack_temp"
    mkdir -p "$temp_dir"
    xcrun libtool -static -o "${temp_dir}/combined.a" "$libmtmd" 2>/dev/null

    local arch_flags=""
    local IFS_OLD="$IFS"
    IFS=';'
    for arch in $archs; do
        arch_flags="$arch_flags -arch $arch"
    done
    IFS="$IFS_OLD"

    local min_version_flag=""
    case "$platform" in
        ios)
            if [ "$is_sim" = "true" ]; then
                min_version_flag="-mios-simulator-version-min=${min_ver}"
            else
                min_version_flag="-mios-version-min=${min_ver}"
            fi
            ;;
        macos)
            min_version_flag="-mmacosx-version-min=${min_ver}"
            ;;
        visionos)
            if [ "$is_sim" = "true" ]; then
                min_version_flag="-mtargetos=xros${min_ver}-simulator"
            else
                min_version_flag="-mtargetos=xros${min_ver}"
            fi
            ;;
        tvos)
            if [ "$is_sim" = "true" ]; then
                min_version_flag="-mtvos-simulator-version-min=${min_ver}"
            else
                min_version_flag="-mtvos-version-min=${min_ver}"
            fi
            ;;
    esac

    # mtmd's symbols transitively reference llama and ggml. The consumer
    # links llama.framework, which provides those. Mark unresolved
    # symbols at framework-build time so we don't fail trying to find them
    # from inside the mtmd .a alone.
    echo "Creating dynamic library for mtmd / ${platform} (${sdk})..."
    xcrun -sdk "$sdk" clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        $arch_flags \
        $min_version_flag \
        -Wl,-undefined,dynamic_lookup \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation \
        -install_name "$install_name" \
        -o "$output_lib"

    # Vtool fix-ups for device builds (matches upstream's script).
    if [ "$is_sim" = "false" ]; then
        if xcrun -f vtool >/dev/null 2>&1; then
            case "$platform" in
                ios)
                    xcrun vtool -set-build-version ios "${min_ver}" "${min_ver}" -replace \
                        -output "$output_lib" "$output_lib"
                    ;;
                tvos)
                    xcrun vtool -set-build-version tvos "${min_ver}" "${min_ver}" -replace \
                        -output "$output_lib" "$output_lib"
                    ;;
                visionos)
                    local vos="visionos"
                    xcrun vtool -set-build-version "$vos" "${min_ver}" "${min_ver}" -replace \
                        -output "$output_lib" "$output_lib" 2>/dev/null || \
                    xcrun vtool -set-build-version xros "${min_ver}" "${min_ver}" -replace \
                        -output "$output_lib" "$output_lib"
                    ;;
            esac
        fi
    fi

    # dSYM split (mirror upstream).
    mkdir -p "${build_dir}/dSYMs"
    if [ "$platform" = "macos" ]; then
        xcrun strip -S "$output_lib" -o "${temp_dir}/stripped_lib"
        xcrun dsymutil "$output_lib" -o "${build_dir}/dSYMs/mtmd.dSYM"
        mv "${temp_dir}/stripped_lib" "$output_lib"
    else
        xcrun dsymutil "$output_lib" -o "${build_dir}/dSYMs/mtmd.dSYM"
        cp "$output_lib" "${temp_dir}/binary_to_strip"
        xcrun strip -S "${temp_dir}/binary_to_strip" -o "${temp_dir}/stripped_lib"
        mv "${temp_dir}/stripped_lib" "$output_lib"
    fi
    if [ -d "${output_lib}.dSYM" ]; then
        rm -rf "${output_lib}.dSYM"
    fi

    rm -rf "$temp_dir"
}

echo "[prepare-xcframework] Packaging mtmd.framework for each platform..."
for entry in "${PLATFORMS[@]}"; do
    IFS=':' read -r build_dir platform sdk archs min_ver is_sim <<< "$entry"
    if [ -f "$build_dir/CMakeCache.txt" ]; then
        package_mtmd_framework "$build_dir" "$platform" "$sdk" "$archs" "$min_ver" "$is_sim"
    fi
done

# Step 4: assemble mtmd.xcframework.
echo "[prepare-xcframework] Creating mtmd.xcframework..."
rm -rf build-apple/mtmd.xcframework
XCF_ARGS=()
for entry in "${PLATFORMS[@]}"; do
    IFS=':' read -r build_dir _ _ _ _ _ <<< "$entry"
    fw="$(pwd)/${build_dir}/framework/mtmd.framework"
    dsym="$(pwd)/${build_dir}/dSYMs/mtmd.dSYM"
    if [ -d "$fw" ]; then
        XCF_ARGS+=(-framework "$fw")
        if [ -d "$dsym" ]; then
            XCF_ARGS+=(-debug-symbols "$dsym")
        fi
    fi
done
xcrun xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$(pwd)/build-apple/mtmd.xcframework"

echo "[prepare-xcframework] Done."
echo "[prepare-xcframework]   $LLAMA_DIR/build-apple/llama.xcframework"
echo "[prepare-xcframework]   $LLAMA_DIR/build-apple/mtmd.xcframework"
