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
    # Shared HTTP-server / handler-dispatch types, plus llama.cpp backend
    # — copied from sibling *-core packages into Sources/_external/ by
    # prepare_command (CocoaPods' file globs do not follow `..` paths
    # reliably across pod boundaries).
    'Sources/_external/DVAISharedCore/**/*.swift',
    'Sources/_external/DVAILlamaCore/**/*.swift',
    'Sources/_external/DVAILlamaCoreObjC/**/*.{h,mm}',
    # NOTE: DVAIFoundationCore is intentionally NOT in the pod. It uses
    # Apple's FoundationModels framework whose import emits implicit
    # autolink directives for private frameworks (SwiftUICore /
    # UIUtilities / CoreAudioTypes) that non-Apple products cannot link.
    # The Foundation Models backend is therefore SwiftPM-only. Calling
    # `.start(BackendKind.foundation)` under a CocoaPods build throws
    # DVAIBridgeError.backendUnavailable with a clear message.
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
    # Mirror sibling-package source dirs into Sources/_external/ so they're
    # visible to CocoaPods' file glob (it doesn't follow `..` paths).
    rm -rf Sources/_external
    mkdir -p Sources/_external
    cp -R ../dvai-bridge-ios-shared-core/ios/Sources/DVAISharedCore Sources/_external/
    cp -R ../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore Sources/_external/
    cp -R ../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC Sources/_external/
    # FoundationCore + MLXCore are intentionally NOT mirrored — see
    # source_files comment.
  SH

  s.vendored_frameworks = [
    'Frameworks/llama.xcframework',
    'Frameworks/mtmd.xcframework',
  ]

  s.frameworks = ['Foundation', 'CoreML', 'AVFoundation', 'CryptoKit']

  # Vendored swift-collections 1.4.1 + swift-jinja 2.3.5 use:
  #   - `package` access level (needs -package-name; SwiftPM auto-sets it)
  #   - `@_lifetime(...)` (needs experimental Lifetimes feature)
  # Set these explicitly for the CocoaPods build so the pod compiles
  # with the same source SwiftPM consumes.
  s.pod_target_xcconfig = {
    'OTHER_SWIFT_FLAGS' => '$(inherited) -package-name DVAIBridgeVendored -enable-experimental-feature Lifetimes',
    # Pin the test-app deployment target to our pod's iOS minimum.
    'IPHONEOS_DEPLOYMENT_TARGET' => '18.1',
    # CocoaPods auto-adds `-framework llama -framework mtmd` to the
    # consumer's app target's OTHER_LDFLAGS but NOT to our pod's own
    # framework target — so symbols from the xcframeworks (referenced
    # by LlamaCppBridge.mm) are unresolved at pod-link time. Add them
    # explicitly here. The xcframework integration script already places
    # the right slice in PODS_XCFRAMEWORKS_BUILD_DIR/DVAIBridge before
    # the link step.
    'OTHER_LDFLAGS' => '$(inherited) -framework "llama" -framework "mtmd"',
  }

  # Telegraph stays at ~> 0.30 because Building42 publishes 0.40+ as GitHub
  # tags only; CocoaPods trunk caps at 0.30.0. Our usage only touches stable
  # core types (Server / HTTPRequest / HTTPResponse / HTTPStatus / HTTPHeaders),
  # so consumers on either channel get a working build.
  s.dependency 'Telegraph', '~> 0.30'
end
