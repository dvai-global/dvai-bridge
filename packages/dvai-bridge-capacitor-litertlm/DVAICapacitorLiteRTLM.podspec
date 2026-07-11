require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# Note: DVAICapacitorLiteRTLM's iOS/macOS build is SwiftPM-only because
# google-ai-edge/LiteRT-LM doesn't publish a CocoaPods spec. CocoaPods
# consumers should use the .llama or .coreml backends via
# DVAICapacitorLlama / DVAICapacitorCoreML, or integrate via SwiftPM
# where LiteRT-LM is available.
#
# This podspec file exists for parity with the other capacitor-*
# packages so `pod lib lint` doesn't trip on its absence. Any attempt
# to actually call DVAIBridgeLiteRTLM.start() from a CocoaPods install
# will fail at link time because the `LiteRTLM` symbols aren't in the
# link line.
#
# When LiteRT-LM publishes a CocoaPods spec, add s.dependency 'LiteRTLM'
# and remove this caveat.

Pod::Spec.new do |s|
  s.name             = 'DVAICapacitorLiteRTLM'
  s.version          = package['version']
  s.summary          = package['description']
  s.license          = 'Custom (See LICENSE)'
  s.homepage         = package['repository']['url']
  s.author           = package['author']
  s.source           = { :git => package['repository']['url'], :tag => s.version.to_s }
  s.source_files     = 'ios/Sources/**/*.{swift,h,m,mm}'
  s.ios.deployment_target = '16.0'
  s.swift_version    = '5.9'
  s.dependency 'Capacitor'
end
