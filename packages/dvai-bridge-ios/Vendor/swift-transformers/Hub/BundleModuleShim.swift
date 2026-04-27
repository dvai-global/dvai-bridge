// SwiftPM auto-generates `Bundle.module` for any target that declares
// resources. CocoaPods does not — and the upstream Hub.swift looks up
// fallback tokenizer configs (gpt2_tokenizer_config.json, etc.) via
// `Bundle.module.url(forResource:)`, so without a shim that file fails
// to compile under CocoaPods with "type 'Bundle' has no member 'module'".
//
// We declare the shim only when SWIFT_PACKAGE is NOT set (i.e. only
// during CocoaPods builds) so SwiftPM's auto-generated `Bundle.module`
// remains the source of truth in that path.
//
// In our podspec the Hub subspec uses `s.resources = […]`, which places
// the JSON files directly into the parent framework's main bundle.
// `Bundle(for: AnyTypeInThisModule.self)` returns that framework bundle,
// so the same `url(forResource:withExtension:)` calls Hub.swift makes
// resolve correctly.

import Foundation

#if !SWIFT_PACKAGE
private final class _DVAIBridgeHubBundleFinder {}

extension Bundle {
    static let module: Bundle = Bundle(for: _DVAIBridgeHubBundleFinder.self)
}
#endif
