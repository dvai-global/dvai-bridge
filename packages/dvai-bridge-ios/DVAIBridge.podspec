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

  s.public_header_files = '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/include/*.h'

  # Tokenizer fallback configs (gpt2_tokenizer_config.json, t5_..) are looked
  # up via Bundle.module by the vendored Hub.swift. Vendor/.../Hub/BundleModuleShim.swift
  # provides Bundle.module under !SWIFT_PACKAGE so the lookup resolves to the
  # framework's main bundle, where these resources land.
  s.resources = ['Vendor/swift-transformers/Hub/Resources/*.json']

  # Prebuilt llama.cpp + mtmd binaries — produced by
  # scripts/mac-side-prepare-xcframework.sh. Both are gitignored; the script
  # rebuilds them whenever the llama.cpp submodule SHA changes.
  s.vendored_frameworks = [
    '../dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple/llama.xcframework',
    '../dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple/mtmd.xcframework',
  ]

  s.frameworks = ['Foundation', 'CoreML']

  # Telegraph stays at ~> 0.30 because Building42 publishes 0.40+ as GitHub
  # tags only; CocoaPods trunk caps at 0.30.0. Our usage only touches stable
  # core types (Server / HTTPRequest / HTTPResponse / HTTPStatus / HTTPHeaders),
  # so consumers on either channel get a working build.
  s.dependency 'Telegraph', '~> 0.30'
end
