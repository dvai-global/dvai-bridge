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
#
# The Sources/_external/ tree (DVAISharedCore + DVAILlamaCore + DVAILlamaCoreObjC
# copied from sibling *-core packages) is PRE-STAGED into the release zip by
# scripts/prepare-ios-release.sh — no `prepare_command` is needed here.
# CocoaPods Trunk has been rejecting specs with prepare_command (server-side
# 500), so we bake the layout in at zip-time.

Pod::Spec.new do |s|
  s.name             = 'DVAIBridge'
  s.version          = package['version']
  s.summary          = package['description']
  s.license          = { :type => 'Custom', :file => 'LICENSE' }
  s.homepage         = 'https://github.com/dvai-global/dvai-bridge'
  s.author           = { 'Deep Chakraborty' => 'chakraborty.deep013@gmail.com' }
  s.source           = {
    :http => "https://github.com/dvai-global/dvai-bridge/releases/download/v#{s.version}/DVAIBridge-v#{s.version}.zip",
    :type => 'zip'
  }
  s.platform         = :ios, '18.1'
  s.swift_version    = '5.9'

  s.source_files = [
    # DVAI core actor + reactive state
    'packages/dvai-bridge-ios/ios/Sources/DVAIBridge/**/*.swift',
    # CoreML backend (uses vendored Tokenizers + Hub + Jinja)
    'packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/**/*.swift',
    # Shared HTTP-server / handler-dispatch types, plus llama.cpp backend
    # — pre-staged in the zip from sibling *-core packages.
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
