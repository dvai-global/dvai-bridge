require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# Subspec layout mirrors our SwiftPM module graph so cross-target imports
# (`import DVAILlamaCore`, `import Tokenizers`, etc.) resolve in CocoaPods
# the same way they do in SwiftPM.
#
#   Core (default) ─┬─► LlamaCore ──► LlamaCoreObjC ──► (llama+mtmd xcframework)
#                   │           ╰─► Telegraph
#                   ├─► FoundationCore ──► Telegraph
#                   └─► CoreMLCore ──► LlamaCore
#                                  └─► Tokenizers ──► Hub ──► Jinja ──► OrderedCollections ──► InternalCollectionsUtilities
#
# The HuggingFace swift-transformers stack (Tokenizers / Hub / Jinja /
# OrderedCollections / InternalCollectionsUtilities) is vendored under
# `Vendor/swift-transformers/` because none of those packages publishes a
# CocoaPods spec. The vendored Hub/HubApi.swift is stripped of network /
# Crypto / yyjson code paths — see Vendor/swift-transformers/Hub/HubApi.swift
# for the rationale. SwiftPM consumers (Package.swift) continue to resolve
# the upstream packages directly and do not see the vendored copies.

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

  # ===========================================================================
  # Vendored swift-transformers stack (not on CocoaPods trunk)
  # ===========================================================================

  s.subspec 'InternalCollectionsUtilities' do |sub|
    sub.source_files = 'Vendor/swift-transformers/InternalCollectionsUtilities/**/*.swift'
    sub.module_name  = 'InternalCollectionsUtilities'
  end

  s.subspec 'OrderedCollections' do |sub|
    sub.source_files = 'Vendor/swift-transformers/OrderedCollections/**/*.swift'
    sub.module_name  = 'OrderedCollections'
    sub.dependency 'DVAIBridge/InternalCollectionsUtilities'
  end

  s.subspec 'Jinja' do |sub|
    sub.source_files = 'Vendor/swift-transformers/Jinja/**/*.swift'
    sub.module_name  = 'Jinja'
    sub.dependency 'DVAIBridge/OrderedCollections'
  end

  s.subspec 'Hub' do |sub|
    sub.source_files = 'Vendor/swift-transformers/Hub/**/*.swift'
    sub.resources    = ['Vendor/swift-transformers/Hub/Resources/*.json']
    sub.module_name  = 'Hub'
    sub.dependency 'DVAIBridge/Jinja'
  end

  s.subspec 'Tokenizers' do |sub|
    sub.source_files = 'Vendor/swift-transformers/Tokenizers/**/*.swift'
    sub.module_name  = 'Tokenizers'
    sub.dependency 'DVAIBridge/Hub'
    sub.dependency 'DVAIBridge/Jinja'
  end

  # ===========================================================================
  # DVAI native cores (mirror the *-core SwiftPM packages)
  # ===========================================================================

  s.subspec 'LlamaCoreObjC' do |sub|
    sub.source_files = '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/**/*.{h,mm}'
    sub.public_header_files = '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/include/*.h'
    sub.module_name  = 'DVAILlamaCoreObjC'
    sub.requires_arc = true
    sub.vendored_frameworks = [
      '../dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple/llama.xcframework',
      '../dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple/mtmd.xcframework',
    ]
    sub.frameworks = ['Foundation']
  end

  s.subspec 'LlamaCore' do |sub|
    sub.source_files = '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/**/*.swift'
    sub.module_name  = 'DVAILlamaCore'
    sub.dependency 'DVAIBridge/LlamaCoreObjC'
    sub.dependency 'Telegraph', '~> 0.30'
  end

  s.subspec 'FoundationCore' do |sub|
    sub.source_files = '../dvai-bridge-ios-foundation-core/ios/Sources/DVAIFoundationCore/**/*.swift'
    sub.module_name  = 'DVAIFoundationCore'
    sub.dependency 'Telegraph', '~> 0.30'
  end

  s.subspec 'CoreMLCore' do |sub|
    sub.source_files = 'ios/Sources/DVAICoreMLCore/**/*.swift'
    sub.module_name  = 'DVAICoreMLCore'
    sub.dependency 'DVAIBridge/LlamaCore'
    sub.dependency 'DVAIBridge/Tokenizers'
    sub.dependency 'Telegraph', '~> 0.30'
  end

  s.subspec 'Core' do |sub|
    sub.source_files = 'ios/Sources/DVAIBridge/**/*.swift'
    sub.module_name  = 'DVAIBridge'
    sub.dependency 'DVAIBridge/LlamaCore'
    sub.dependency 'DVAIBridge/FoundationCore'
    sub.dependency 'DVAIBridge/CoreMLCore'
  end

  s.default_subspecs = ['Core']
end
