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

LLAMA_DIR="packages/dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp"
LLAMA_XCF_PATH="$LLAMA_DIR/build-apple/llama.xcframework"
MTMD_XCF_PATH="$LLAMA_DIR/build-apple/mtmd.xcframework"
# Short-circuit also requires the Mac Catalyst slice in both xcframeworks
# — that's what Step 5/6 add on top of upstream's output. Without this
# check, a partially-built tree (upstream produced the non-Catalyst
# slices, but the Catalyst additions never ran or were interrupted)
# would be considered "done" forever.
LLAMA_CATALYST_SLICE="$LLAMA_XCF_PATH/ios-arm64_x86_64-maccatalyst"
MTMD_CATALYST_SLICE="$MTMD_XCF_PATH/ios-arm64_x86_64-maccatalyst"

if [ -d "$LLAMA_XCF_PATH" ] && [ -d "$MTMD_XCF_PATH" ] \
        && [ -d "$LLAMA_CATALYST_SLICE" ] && [ -d "$MTMD_CATALYST_SLICE" ] \
        && [ "${FORCE:-0}" != "1" ]; then
    echo "[prepare-xcframework] llama.xcframework + mtmd.xcframework with Catalyst slice already exist; skipping rebuild."
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
# Mac Catalyst — iOS-shaped target running on macOS. The clang target
# triple is `<arch>-apple-ios<ios-version>-macabi`, but the LINKER
# version flag is `-mmacosx-version-min=<macos-version>` (Catalyst
# requires a macOS version that supports that iOS version). Apple's
# mapping: iOS 18.x Catalyst <-> macOS 15.x. Keep MACCATALYST_IOS_VERSION
# in sync with the iOS umbrella's `.iOS("18.1")` declaration in
# packages/dvai-bridge-ios/Package.swift; bump MACCATALYST_MACOS_VERSION
# accordingly if iOS floor changes (iOS 17 -> macOS 14, iOS 19 -> macOS 16).
MACCATALYST_IOS_VERSION=18.1
MACCATALYST_MACOS_VERSION=15.0

# Step 1: build llama.xcframework via upstream's script.
if [ ! -d "build-apple/llama.xcframework" ] || [ "${FORCE:-0}" = "1" ]; then
    echo "[prepare-xcframework] Running build-xcframework.sh (this takes ~5-15 min)..."
    bash build-xcframework.sh
else
    echo "[prepare-xcframework] llama.xcframework exists; skipping upstream build."
fi
echo "[prepare-xcframework] llama.xcframework -> $LLAMA_DIR/build-apple/llama.xcframework"

# Step 1.5: bootstrap build-catalyst directory (upstream's build-xcframework.sh
# doesn't know about Catalyst). Configures CMake with the Catalyst target
# triple (-target <arch>-apple-ios18.1-macabi) + macOS SDK at deployment
# target 15.0 (the macOS version that supports iOS 18.x Catalyst).
# Both archs build into one dir so cmake's caching + parallelism works;
# arch-specific .o files end up under per-arch subdirs of CMakeFiles/.
# Step 5 later lipos the two arch-specific static libs together.
#
# `-mmacosx-version-min=18.1` would error with "invalid version" (macOS
# 18.x doesn't exist) — must use MACOS_VERSION=15.0 even though the
# clang -target says ios18.1.
if [ ! -f "build-catalyst-arm64/CMakeCache.txt" ] || [ "${FORCE:-0}" = "1" ]; then
    echo "[prepare-xcframework] Bootstrap build-catalyst-arm64 (Catalyst arm64)..."
    rm -rf build-catalyst-arm64
    cmake -B build-catalyst-arm64 \
        -DCMAKE_SYSTEM_NAME=Darwin \
        -DCMAKE_OSX_SYSROOT=macosx \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACCATALYST_MACOS_VERSION}" \
        -DCMAKE_C_FLAGS="-target arm64-apple-ios${MACCATALYST_IOS_VERSION}-macabi" \
        -DCMAKE_CXX_FLAGS="-target arm64-apple-ios${MACCATALYST_IOS_VERSION}-macabi" \
        -DCMAKE_ASM_FLAGS="-target arm64-apple-ios${MACCATALYST_IOS_VERSION}-macabi" \
        -DBUILD_SHARED_LIBS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_TOOLS=OFF \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_SERVER=OFF \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_METAL_USE_BF16=ON \
        -DGGML_BLAS_DEFAULT=ON \
        -DGGML_NATIVE=OFF \
        -DGGML_OPENMP=OFF \
        > /dev/null
fi
if [ ! -f "build-catalyst-x86_64/CMakeCache.txt" ] || [ "${FORCE:-0}" = "1" ]; then
    echo "[prepare-xcframework] Bootstrap build-catalyst-x86_64 (Catalyst x86_64)..."
    rm -rf build-catalyst-x86_64
    cmake -B build-catalyst-x86_64 \
        -DCMAKE_SYSTEM_NAME=Darwin \
        -DCMAKE_OSX_SYSROOT=macosx \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACCATALYST_MACOS_VERSION}" \
        -DCMAKE_C_FLAGS="-target x86_64-apple-ios${MACCATALYST_IOS_VERSION}-macabi" \
        -DCMAKE_CXX_FLAGS="-target x86_64-apple-ios${MACCATALYST_IOS_VERSION}-macabi" \
        -DCMAKE_ASM_FLAGS="-target x86_64-apple-ios${MACCATALYST_IOS_VERSION}-macabi" \
        -DBUILD_SHARED_LIBS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_TOOLS=OFF \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_SERVER=OFF \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_METAL_USE_BF16=ON \
        -DGGML_BLAS_DEFAULT=ON \
        -DGGML_NATIVE=OFF \
        -DGGML_OPENMP=OFF \
        > /dev/null
fi

# Build llama (without tools) for both Catalyst archs. mtmd build comes
# later in the existing PLATFORMS reconfigure loop — but that loop
# expects ONE build_dir per platform. For Catalyst we maintain two
# (one per arch) and lipo them in Step 5; the loop only sees `build-catalyst`
# (a symlink to the arm64 dir for the mtmd-target build), and the x86_64
# variant of mtmd is built in its own dir at the same time.
echo "[prepare-xcframework] Build llama for Catalyst arm64..."
cmake --build build-catalyst-arm64 --config Release --target llama -- -j -s
echo "[prepare-xcframework] Build llama for Catalyst x86_64..."
cmake --build build-catalyst-x86_64 --config Release --target llama -- -j -s
# Reconfigure both Catalyst dirs with LLAMA_BUILD_TOOLS=ON + build mtmd.
echo "[prepare-xcframework] Reconfigure Catalyst dirs + build mtmd..."
for arch_dir in build-catalyst-arm64 build-catalyst-x86_64; do
    cmake -B "$arch_dir" \
        -DLLAMA_BUILD_TOOLS=ON \
        -DLLAMA_BUILD_COMMON=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_SERVER=OFF \
        > /dev/null
    cmake --build "$arch_dir" --config Release --target mtmd -- -j -s
done

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
# Mac Catalyst handled separately below — the clang `-target` triple
# embeds the arch, so it can't be a single multi-arch CMake configure
# the way build-macos / build-ios-sim are. Built as two per-arch dirs
# (build-catalyst-arm64 + build-catalyst-x86_64) then lipo'd together.

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

    # Public mtmd headers. Upstream mtmd.h / mtmd-helper.h do
    # `#include "ggml.h"` and `#include "llama.h"` (quoted form), which
    # Clang searches only within the framework's own Headers/ — and
    # finding a copy there would cause symbol redefinitions when the
    # consumer also imports llama.framework. We patch the quoted
    # includes to angle-bracket form (`<llama/ggml.h>`, `<llama/llama.h>`)
    # so they resolve through llama.framework's module instead.
    # The local mtmd.h <-> mtmd-helper.h reference stays quoted.
    cp tools/mtmd/mtmd.h         "$header_path/"
    cp tools/mtmd/mtmd-helper.h  "$header_path/"
    sed -i.bak \
        -e 's|#include "ggml.h"|#include <llama/ggml.h>|g' \
        -e 's|#include "llama.h"|#include <llama/llama.h>|g' \
        "$header_path/mtmd.h" "$header_path/mtmd-helper.h"
    rm -f "$header_path/mtmd.h.bak" "$header_path/mtmd-helper.h.bak"

    # The modulemap declares `use llama` so Clang knows to satisfy the
    # angle-bracket includes via the sibling llama framework module.
    cat > "${module_path}/module.modulemap" <<'EOF'
framework module mtmd {
    use llama
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

# Step 5: assemble Mac Catalyst slices and repackage both xcframeworks.
#
# Upstream's build-xcframework.sh produces llama.xcframework without a
# Catalyst slice (ggml-org/llama.cpp#12751 closed-stale). The mtmd.xcframework
# assembled above also lacks Catalyst because the PLATFORMS loop doesn't
# include it. Both are needed for the .NET MAUI Mac Catalyst TFM
# (net10.0-maccatalyst*) to link cleanly — without them, dotnet build
# errors with "no library for this platform was found in 'llama.xcframework'".
#
# We:
#   1. Lipo arm64 + x86_64 libllama + libggml-* libs from each per-arch
#      build-catalyst-<arch> dir into combined fat libs.
#   2. Package as a macOS-style llama.framework (Versions/A/ structure —
#      Catalyst frameworks use the macOS shape, not iOS-flat).
#   3. Same for mtmd.
#   4. Recreate both xcframeworks with all existing slices + the new
#      ios-arm64_x86_64-maccatalyst slice via xcodebuild -create-xcframework.

echo "[prepare-xcframework] Building Mac Catalyst slices..."

# Helper: lipo a list of .a files from each arch dir into a fat archive.
# Args: <output> <relative-path> <arch1-build-dir> <arch2-build-dir>
catalyst_lipo() {
    local out="$1"
    local rel_path="$2"
    local arch_dir_1="$3"
    local arch_dir_2="$4"
    local lib1="${arch_dir_1}/${rel_path}"
    local lib2="${arch_dir_2}/${rel_path}"
    if [ ! -f "$lib1" ] || [ ! -f "$lib2" ]; then
        echo "[prepare-xcframework] WARN: missing ${rel_path} in one of the Catalyst arch dirs ($lib1 / $lib2)"
        return 1
    fi
    xcrun lipo -create "$lib1" "$lib2" -output "$out"
}

# Combine multiple .a static libs into one (libtool -static), so the final
# framework only needs to load a single archive. Catalyst frameworks
# linking against llama.framework expect the binary to resolve ALL the
# ggml + llama symbols; combining keeps the link simple at consumer time.
catalyst_combine_libs() {
    local out="$1"
    shift
    xcrun libtool -static -o "$out" "$@" 2>/dev/null
}

# Package the combined .a as a macOS-style framework (Catalyst frameworks
# use the same Versions/A/ symlink layout as macOS frameworks).
catalyst_package_framework() {
    local fw_root="$1"
    local fw_name="$2"
    local combined_lib="$3"
    local headers_src_dir="$4"  # optional: directory of headers to copy
    local install_name="$5"
    local module_map_extra="$6"  # optional: extra modulemap content

    rm -rf "$fw_root"
    mkdir -p "${fw_root}/Versions/A/Headers"
    mkdir -p "${fw_root}/Versions/A/Modules"
    mkdir -p "${fw_root}/Versions/A/Resources"
    ln -sf A "${fw_root}/Versions/Current"
    ln -sf Versions/Current/Headers "${fw_root}/Headers"
    ln -sf Versions/Current/Modules "${fw_root}/Modules"
    ln -sf Versions/Current/Resources "${fw_root}/Resources"
    ln -sf "Versions/Current/${fw_name}" "${fw_root}/${fw_name}"

    # Convert .a to a dynamic framework binary (Catalyst frameworks must
    # be dynlibs to be linked by Xcode's framework lookup; static .a's
    # need a different consumer path that .NET MAUI's binding tooling
    # doesn't take). The -Wl,-undefined,dynamic_lookup leaves cross-
    # framework symbol references for runtime resolution (e.g. mtmd
    # depends on llama+ggml symbols which the consumer also links via
    # llama.framework).
    xcrun -sdk macosx clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
        -arch arm64 -arch x86_64 \
        -target arm64-apple-ios"${MACCATALYST_IOS_VERSION}"-macabi \
        -mmacosx-version-min="${MACCATALYST_MACOS_VERSION}" \
        -Wl,-undefined,dynamic_lookup \
        -Wl,-force_load,"$combined_lib" \
        -framework Foundation \
        -install_name "$install_name" \
        -o "${fw_root}/Versions/A/${fw_name}"

    # Headers (best-effort — only if a source dir was provided).
    if [ -n "$headers_src_dir" ] && [ -d "$headers_src_dir" ]; then
        cp -R "$headers_src_dir"/*.h "${fw_root}/Versions/A/Headers/" 2>/dev/null || true
    fi

    # Module map (basic — exports headers as a Swift/Obj-C module).
    cat > "${fw_root}/Versions/A/Modules/module.modulemap" <<EOF
framework module ${fw_name} {
    umbrella header "${fw_name}.h"
${module_map_extra}
    link "c++"
    export *
}
EOF

    # Info.plist matching what Xcode emits for Mac Catalyst frameworks.
    cat > "${fw_root}/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${fw_name}</string>
    <key>CFBundleIdentifier</key><string>org.ggml.${fw_name}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${fw_name}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>${MACCATALYST_IOS_VERSION}</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>DTPlatformName</key><string>macosx</string>
    <key>DTSDKName</key><string>macosx${MACCATALYST_MACOS_VERSION}</string>
</dict>
</plist>
EOF
}

# --- llama Catalyst slice ---
CATALYST_LLAMA_TMP="build-catalyst-fat"
rm -rf "$CATALYST_LLAMA_TMP"
mkdir -p "$CATALYST_LLAMA_TMP"

# Lipo each underlying static lib.
for rel in \
    "src/libllama.a" \
    "ggml/src/libggml.a" \
    "ggml/src/libggml-base.a" \
    "ggml/src/libggml-cpu.a" \
    "ggml/src/ggml-blas/libggml-blas.a" \
    "ggml/src/ggml-metal/libggml-metal.a" \
    ; do
    if [ -f "build-catalyst-arm64/$rel" ] || [ -f "build-catalyst-x86_64/$rel" ]; then
        out="${CATALYST_LLAMA_TMP}/$(basename $rel)"
        catalyst_lipo "$out" "$rel" build-catalyst-arm64 build-catalyst-x86_64
    fi
done

# Combine into one (matching what upstream's combine_static_libraries does
# for the other slices). list every fat .a we just produced.
LLAMA_COMBINED="${CATALYST_LLAMA_TMP}/combined-llama.a"
catalyst_combine_libs "$LLAMA_COMBINED" \
    "${CATALYST_LLAMA_TMP}"/libllama.a \
    "${CATALYST_LLAMA_TMP}"/libggml*.a

CATALYST_LLAMA_FW="${CATALYST_LLAMA_TMP}/llama.framework"
catalyst_package_framework \
    "$CATALYST_LLAMA_FW" \
    "llama" \
    "$LLAMA_COMBINED" \
    "include" \
    "@rpath/llama.framework/Versions/A/llama" \
    ""

# --- mtmd Catalyst slice ---
CATALYST_MTMD_TMP="build-catalyst-mtmd-fat"
rm -rf "$CATALYST_MTMD_TMP"
mkdir -p "$CATALYST_MTMD_TMP"

catalyst_lipo \
    "${CATALYST_MTMD_TMP}/libmtmd.a" \
    "tools/mtmd/Release/libmtmd.a" \
    build-catalyst-arm64 build-catalyst-x86_64 || \
catalyst_lipo \
    "${CATALYST_MTMD_TMP}/libmtmd.a" \
    "tools/mtmd/libmtmd.a" \
    build-catalyst-arm64 build-catalyst-x86_64

CATALYST_MTMD_COMBINED="${CATALYST_MTMD_TMP}/combined-mtmd.a"
catalyst_combine_libs "$CATALYST_MTMD_COMBINED" "${CATALYST_MTMD_TMP}/libmtmd.a"

CATALYST_MTMD_FW="${CATALYST_MTMD_TMP}/mtmd.framework"
catalyst_package_framework \
    "$CATALYST_MTMD_FW" \
    "mtmd" \
    "$CATALYST_MTMD_COMBINED" \
    "tools/mtmd" \
    "@rpath/mtmd.framework/Versions/A/mtmd" \
    ""

# Step 6: repackage llama.xcframework + mtmd.xcframework with the new
# Catalyst slice included. xcodebuild -create-xcframework rebuilds from
# a list of frameworks — extract the existing slices from the existing
# xcframework dirs (each subdir except Info.plist is a slice), then
# pass them + the new Catalyst framework.
echo "[prepare-xcframework] Repackaging xcframeworks with Catalyst slice..."
for which in llama mtmd; do
    src_xcf="build-apple/${which}.xcframework"
    new_xcf="build-apple/${which}-with-catalyst.xcframework"
    [ -d "$src_xcf" ] || { echo "[prepare-xcframework] WARN: $src_xcf missing"; continue; }

    # Bail if Catalyst slice already present — xcodebuild won't accept
    # duplicates and rebuilding for no reason wastes minutes on cold-cache
    # CI runs (the cache action keys on this dir).
    if [ -d "${src_xcf}/ios-arm64_x86_64-maccatalyst" ]; then
        echo "[prepare-xcframework]   $which already has Catalyst slice; skipping."
        continue
    fi

    args=()
    while IFS= read -r slice_dir; do
        slice_name=$(basename "$slice_dir")
        # Each slice dir contains one .framework — find it.
        fw=$(find "$slice_dir" -maxdepth 2 -name '*.framework' -type d | head -n 1)
        if [ -n "$fw" ]; then
            args+=(-framework "$(pwd)/$fw")
        fi
    done < <(find "$src_xcf" -mindepth 1 -maxdepth 1 -type d)

    # Append the new Catalyst framework.
    if [ "$which" = "llama" ]; then
        args+=(-framework "$(pwd)/${CATALYST_LLAMA_FW}")
    else
        args+=(-framework "$(pwd)/${CATALYST_MTMD_FW}")
    fi

    rm -rf "$new_xcf"
    xcrun xcodebuild -create-xcframework "${args[@]}" -output "$new_xcf"
    rm -rf "$src_xcf"
    mv "$new_xcf" "$src_xcf"
    echo "[prepare-xcframework]   $which.xcframework now includes Catalyst slice:"
    ls "$src_xcf"
done

echo "[prepare-xcframework] Done."
echo "[prepare-xcframework]   $LLAMA_DIR/build-apple/llama.xcframework"
echo "[prepare-xcframework]   $LLAMA_DIR/build-apple/mtmd.xcframework"
