require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# NOTE: swift-transformers (HuggingFace) and Telegraph are required at
# link time. Telegraph has a CocoaPods spec ('Telegraph') and is declared
# via s.dependency below. swift-transformers does NOT have a CocoaPods
# spec; consumers using DVAIBridge via CocoaPods must add it via SwiftPM
# or vendor its sources separately. SwiftPM consumers get it
# automatically via Package.swift.

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
  s.source_files     = [
    'ios/Sources/DVAIBridge/**/*.{swift}',
    'ios/Sources/DVAICoreMLCore/**/*.{swift}',
    '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/**/*.{swift}',
    '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/**/*.{h,mm}',
    '../dvai-bridge-ios-foundation-core/ios/Sources/DVAIFoundationCore/**/*.{swift}',
  ]
  s.public_header_files = '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/include/*.h'
  s.dependency 'Telegraph', '~> 0.40'
  s.vendored_frameworks = [
    '../dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple/llama.xcframework',
    '../dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple/mtmd.xcframework',
  ]
end
