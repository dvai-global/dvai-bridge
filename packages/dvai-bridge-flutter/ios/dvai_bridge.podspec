# dvai_bridge — Flutter plugin podspec.
#
# This pod is **thin**: it does not embed any inference engine, model
# downloader, or HTTP server. All of that lives in the `DVAIBridge`
# umbrella pod (declared as `s.dependency` below). This pod's only job is
# to translate Pigeon-generated platform-channel calls from the Dart side
# into Swift calls against `DVAIBridge.shared` and forward
# `progressPublisher` events back as a `FlutterEventChannel` stream.
#
# CocoaPods caveats (carry over from the underlying DVAIBridge umbrella):
#
#   - `.foundation` and `.mlx` BackendKind cases throw
#     `DVAIBridgeError.backendUnavailable` under CocoaPods builds. Apple's
#     `FoundationModels` framework triggers private-framework autolink
#     directives CocoaPods consumers cannot link, and `mlx-swift-lm`'s
#     transitive deps don't publish CocoaPods specs. SwiftPM consumers (via
#     `pod 'DVAIBridge', :path => '...' ` in their Podfile) get full
#     coverage. See docs/guide/flutter-sdk.md "MLX under CocoaPods" for the
#     workaround.
#
# Flutter consumers always go through CocoaPods (Flutter doesn't
# auto-route to SwiftPM), so .foundation / .mlx are practically
# unavailable to plain `flutter pub add dvai_bridge` users — they'll need
# the path-based-pod workaround.

Pod::Spec.new do |s|
  s.name             = 'dvai_bridge'
  s.version          = '2.2.0'
  s.summary          = 'Flutter plugin for the DVAIBridge local-LLM SDK (iOS / Android).'
  s.description      = <<-DESC
    Pigeon-driven Flutter plugin that wraps the Phase 3C iOS SDK
    (`DVAIBridge` SwiftPM/CocoaPods) and Phase 3D Android SDK
    (`co.deepvoiceai:dvai-bridge` AAR) behind a single Dart facade.
    Exposes a 4-method lifecycle API (start / stop / status / downloadModel)
    plus reactive `Stream<DVAIBridgeState>` and `Stream<ProgressEvent>`
    getters.
  DESC
  s.homepage         = 'https://github.com/Westenets/dvai-bridge'
  s.license          = { :type => 'Custom', :file => '../LICENSE' }
  s.author           = { 'Deep Chakraborty' => 'https://github.com/dk013' }
  s.source           = { :git => 'https://github.com/Westenets/dvai-bridge.git', :tag => "v#{s.version}" }
  s.platform         = :ios, '15.1'
  s.swift_version    = '5.9'

  s.source_files = 'Classes/**/*.{swift,h,m}'
  s.requires_arc = true

  # Flutter — always required for a Flutter plugin pod.
  s.dependency 'Flutter'

  # Phase 3C umbrella pod — provides `DVAIBridge.shared`, `BackendKind`,
  # `DVAIBridgeError`, `ProgressEvent`, `BoundServer`, `DVAIBridgeConfig`.
  # Pinned with `~> 2.2` so 2.2.x and 2.3.x patches resolve cleanly without
  # breaking-change risk.
  s.dependency 'DVAIBridge', '~> 2.2'

  # Flutter plugin convention — defines the Swift module so the plugin
  # class is importable from generated `GeneratedPluginRegistrant.m`.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_VERSION'  => '5.9',
  }
end
