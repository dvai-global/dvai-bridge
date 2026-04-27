require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

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
  s.license          = { :type => 'Custom', :file => '../../LICENSE' }
  s.homepage         = 'https://github.com/Westenets/dvai-bridge'
  s.author           = package['author']
  s.source           = { :git => 'https://github.com/Westenets/dvai-bridge.git', :tag => "v#{s.version}" }
  s.platform         = :ios, '18.1'
  s.swift_version    = '5.9'

  s.source_files = [
    # DVAI core actor + reactive state
    'ios/Sources/DVAIBridge/**/*.swift',
    # CoreML backend (uses vendored Tokenizers + Hub + Jinja)
    'ios/Sources/DVAICoreMLCore/**/*.swift',
    # llama.cpp backend Swift + ObjC++ bridge
    '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/**/*.swift',
    '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/**/*.{h,mm}',
    # Foundation Models (iOS 26+) backend
    '../dvai-bridge-ios-foundation-core/ios/Sources/DVAIFoundationCore/**/*.swift',
    # Vendored swift-transformers stack — see Vendor/swift-transformers/ for
    # upstream attributions and the rationale for stripping HubApi.swift.
    'Vendor/swift-transformers/Tokenizers/**/*.swift',
    'Vendor/swift-transformers/Hub/**/*.swift',
    'Vendor/swift-transformers/Jinja/**/*.swift',
    'Vendor/swift-transformers/OrderedCollections/**/*.swift',
    'Vendor/swift-transformers/InternalCollectionsUtilities/**/*.swift',
  ]

  # Tokenizer fallback configs (gpt2_tokenizer_config.json, t5_..) are looked
  # up via Bundle.module by the vendored Hub.swift. Vendor/.../Hub/BundleModuleShim.swift
  # provides Bundle.module under !SWIFT_PACKAGE so the lookup resolves to the
  # framework's main bundle, where these resources land.
  s.resources = ['Vendor/swift-transformers/Hub/Resources/*.json']

  # CocoaPods' pod-validator treats the pod as a self-contained tree and
  # refuses `..` paths in `vendored_frameworks`. The xcframeworks are
  # produced by scripts/mac-side-prepare-xcframework.sh in the llama.cpp
  # submodule's build-apple/ directory (so SwiftPM's binaryTarget paths
  # resolve from Package.swift). For CocoaPods we copy them into a
  # pod-local Frameworks/ folder via prepare_command, which runs in the
  # source tree before validation.
  s.prepare_command = <<-SH
    set -e
    XCF_SRC="../dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple"
    mkdir -p Frameworks
    if [ -d "$XCF_SRC/llama.xcframework" ]; then
      rm -rf Frameworks/llama.xcframework
      cp -R "$XCF_SRC/llama.xcframework" Frameworks/llama.xcframework
    fi
    if [ -d "$XCF_SRC/mtmd.xcframework" ]; then
      rm -rf Frameworks/mtmd.xcframework
      cp -R "$XCF_SRC/mtmd.xcframework" Frameworks/mtmd.xcframework
    fi
  SH

  s.vendored_frameworks = [
    'Frameworks/llama.xcframework',
    'Frameworks/mtmd.xcframework',
  ]

  s.frameworks = ['Foundation', 'CoreML']

  # Vendored swift-collections 1.4.1 + swift-jinja 2.3.5 use:
  #   - `package` access level (needs -package-name; SwiftPM auto-sets it)
  #   - `@_lifetime(...)` (needs experimental Lifetimes feature)
  # Set these explicitly for the CocoaPods build so the pod compiles
  # with the same source SwiftPM consumes.
  s.pod_target_xcconfig = {
    'OTHER_SWIFT_FLAGS' => '$(inherited) -package-name DVAIBridgeVendored -enable-experimental-feature Lifetimes',
  }

  # Telegraph stays at ~> 0.30 because Building42 publishes 0.40+ as GitHub
  # tags only; CocoaPods trunk caps at 0.30.0. Our usage only touches stable
  # core types (Server / HTTPRequest / HTTPResponse / HTTPStatus / HTTPHeaders),
  # so consumers on either channel get a working build.
  s.dependency 'Telegraph', '~> 0.30'
end
