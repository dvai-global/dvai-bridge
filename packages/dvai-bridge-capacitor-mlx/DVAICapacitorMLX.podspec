require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# Note: DVAICapacitorMLX intentionally has no CocoaPods integration
# because mlx-swift-lm + mlx-swift transitive deps don't publish
# CocoaPods specs. CocoaPods consumers should use the .llama or
# .coreml backends via DVAICapacitorLlama / DVAICapacitorCoreML, or
# integrate via SwiftPM where MLX is available.
#
# This podspec file exists for parity with the other capacitor-*
# packages so `pod lib lint` doesn't trip on its absence — the
# embedded source files compile and the pod links into the app, but
# any attempt to call DVAIBridgeMLX.start() will throw because the
# `MLXLMCommon` symbols aren't in the link line.
#
# When mlx-swift-lm publishes a CocoaPods spec (or we vendor the full
# stack the way we did for swift-transformers in DVAIBridge.podspec),
# update s.dependency to add it and remove this caveat.

Pod::Spec.new do |s|
  s.name             = 'DVAICapacitorMLX'
  s.version          = package['version']
  s.summary          = package['description']
  s.license          = 'Custom (See LICENSE)'
  s.homepage         = package['repository']['url']
  s.author           = package['author']
  s.source           = { :git => package['repository']['url'], :tag => s.version.to_s }
  s.source_files     = 'ios/Sources/**/*.{swift,h,m,mm}'
  s.ios.deployment_target = '17.0'
  s.swift_version    = '5.9'
  s.dependency 'Capacitor'
end
