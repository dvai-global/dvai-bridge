require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'packages/dvai-bridge-ios/package.json')))

# CocoaPods doesn't allow per-subspec `module_name`, so the whole pod compiles
# into a single Swift module called `DVAIBridge`. Cross-target imports inside
# our SwiftPM module graph (e.g. `import DVAILlamaCore`, `import Tokenizers`)
# are wrapped with `#if !COCOAPODS` (see scripts/wrap-cocoapods-imports.py)
# so they remain real imports under SwiftPM and become no-ops here, where
# everything is already same-module. SwiftPM consumers continue to resolve
# the upstream swift-transformers / swift-jinja / swift-collections packages
# through Package.swift; only CocoaPods consumers see the vendored copies
# under Vendor/swift-transformers/.

Pod::Spec.new do |s|
  s.name             = 'DVAIBridge'
  s.version          = package['version']
  s.summary          = package['description']
  s.license          = { :type => 'Custom', :file => 'LICENSE' }
  s.homepage         = 'https://github.com/dvai-global/dvai-bridge'
  s.author           = package['author']
  s.source           = { :git => 'https://github.com/dvai-global/dvai-bridge.git', :tag => "v#{s.version}" }
  s.platform         = :ios, '18.1'
  s.swift_version    = '5.9'

  s.source_files = [
    # DVAI core actor + reactive state
    'packages/dvai-bridge-ios/ios/Sources/DVAIBridge/**/*.swift',
    # CoreML backend (uses vendored Tokenizers + Hub + Jinja)
    'packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/**/*.swift',
    # Shared HTTP-server / handler-dispatch types, plus llama.cpp backend
    # — copied from sibling *-core packages into Sources/_external/ by
    # prepare_command.
    'packages/dvai-bridge-ios/Sources/_external/DVAISharedCore/**/*.swift',
    'packages/dvai-bridge-ios/Sources/_external/DVAILlamaCore/**/*.swift',
    'packages/dvai-bridge-ios/Sources/_external/DVAILlamaCoreObjC/**/*.{h,mm}',
    # Vendored swift-transformers stack
    'packages/dvai-bridge-ios/Vendor/swift-transformers/Tokenizers/**/*.swift',
    'packages/dvai-bridge-ios/Vendor/swift-transformers/Hub/**/*.swift',
    'packages/dvai-bridge-ios/Vendor/swift-transformers/Jinja/**/*.swift',
    'packages/dvai-bridge-ios/Vendor/swift-transformers/OrderedCollections/**/*.swift',
    'packages/dvai-bridge-ios/Vendor/swift-transformers/InternalCollectionsUtilities/**/*.swift',
  ]

  s.resources = ['packages/dvai-bridge-ios/Vendor/swift-transformers/Hub/Resources/*.json']

  # Prepare command runs from the podspec's directory (now repo root).
  s.prepare_command = <<-SH
    set -e
    XCF_SRC="packages/dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple"
    IOS_PKG="packages/dvai-bridge-ios"
    
    mkdir -p "$IOS_PKG/Frameworks"
    
    # Copy frameworks if they exist (built locally or during CI)
    if [ -d "$XCF_SRC/llama.xcframework" ]; then
      rm -rf "$IOS_PKG/Frameworks/llama.xcframework"
      cp -R "$XCF_SRC/llama.xcframework" "$IOS_PKG/Frameworks/llama.xcframework"
    fi
    if [ -d "$XCF_SRC/mtmd.xcframework" ]; then
      rm -rf "$IOS_PKG/Frameworks/mtmd.xcframework"
      cp -R "$XCF_SRC/mtmd.xcframework" "$IOS_PKG/Frameworks/mtmd.xcframework"
    fi
    
    # Mirror sibling-package source dirs into Sources/_external/
    rm -rf "$IOS_PKG/Sources/_external"
    mkdir -p "$IOS_PKG/Sources/_external"
    
    cp -R packages/dvai-bridge-ios-shared-core/ios/Sources/DVAISharedCore "$IOS_PKG/Sources/_external/"
    cp -R packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore "$IOS_PKG/Sources/_external/"
    cp -R packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC "$IOS_PKG/Sources/_external/"
  SH

  s.vendored_frameworks = [
    'packages/dvai-bridge-ios/Frameworks/llama.xcframework',
    'packages/dvai-bridge-ios/Frameworks/mtmd.xcframework',
  ]

  s.frameworks = ['Foundation', 'CoreML', 'AVFoundation', 'CryptoKit']

  s.pod_target_xcconfig = {
    'OTHER_SWIFT_FLAGS' => '$(inherited) -package-name DVAIBridgeVendored -enable-experimental-feature Lifetimes',
    'IPHONEOS_DEPLOYMENT_TARGET' => '18.1',
    'OTHER_LDFLAGS' => '$(inherited) -framework "llama" -framework "mtmd"',
  }

  s.dependency 'Telegraph', '~> 0.30'
end
