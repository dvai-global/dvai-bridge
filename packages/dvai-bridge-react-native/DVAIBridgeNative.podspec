require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# DVAIBridgeNative — the React Native TurboModule bridge for the
# `@dvai-bridge/react-native` package.
#
# This pod is **thin**: it does not embed any inference engine, model
# downloader, or HTTP server. All of that lives in the `DVAIBridge` umbrella
# pod (declared as a `s.dependency` below). This pod's only responsibility
# is to translate JS-side TurboModule calls into Swift calls against
# `DVAIBridge.shared` and forward `progressPublisher` events back as
# `RCTEventEmitter`-style events.
#
# CocoaPods caveat carried over from the underlying DVAIBridge pod:
#   - The `.foundation` and `.mlx` BackendKind cases throw
#     `DVAIBridgeError.backendUnavailable` under CocoaPods builds — the
#     respective Swift libraries' transitive deps trigger private-framework
#     autolink directives CocoaPods consumers cannot link. SwiftPM
#     consumers (e.g. via `:path` in Podfile) get full coverage.
#
# The iOS minimum is 15.1 to match `react-native@0.85.x`'s floor; the
# `DVAIBridge` umbrella is iOS 18.1 and runs higher, so any consumer who
# can build the DVAIBridge pod will see the bridge's iOS-15.1 code path
# fold into their iOS-18.1 link line cleanly. (Keeping our floor at 15.1
# here lets RN's auto-generated test apps with the standard 15.1 minimum
# resolve the spec without bumping.)

Pod::Spec.new do |s|
  s.name             = 'DVAIBridgeNative'
  s.version          = package['version']
  s.summary          = package['description']
  s.license          = { :type => 'Custom', :file => '../../LICENSE' }
  s.homepage         = 'https://github.com/dvai-global/dvai-bridge'
  s.author           = package['author']
  s.source           = { :git => 'https://github.com/dvai-global/dvai-bridge.git', :tag => "v#{s.version}" }
  s.platform         = :ios, '15.1'
  s.swift_version    = '5.9'

  s.source_files = 'ios/*.{swift,h,m,mm}'
  s.requires_arc   = true

  # Dependency on the DVAIBridge umbrella pod (Phase 3C v2.1) — provides
  # `DVAIBridge.shared`, `BackendKind`, `DVAIBridgeError`, `ProgressEvent`,
  # `BoundServer`, `DVAIBridgeConfig`. Pinned to the same minor that this
  # package version targets.
  s.dependency 'DVAIBridge', '~> 2.1'

  # React Native New Architecture install hook. Picked up by `pod install`
  # in any RN ≥ 0.74 app; populates the right preprocessor flags, header
  # search paths, and codegen entries for the TurboModule.
  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  else
    # Fallback for RN < 0.74 (defensive — we declare RN ≥ 0.77 as the peer-
    # dep floor, but this path keeps `pod lib lint` green if someone runs
    # it against an older RN install).
    s.dependency 'React-Core'
  end
end
