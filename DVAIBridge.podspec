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
  # CocoaPods Trunk + cocoapods.org render `description` on the pod's
  # landing page below the summary. This is positioning copy aimed at
  # iOS devs who land here from a search and ask "isn't this just
  # llama.cpp / MLX-Swift / Apple Foundation Models?" — the answer is
  # 'no, those are runtimes; this is a runtime PLUS a real OpenAI
  # HTTP surface inside your app process, same wire as every other
  # platform in the dvai-bridge family'.
  s.description      = <<-DESC
    DVAIBridge embeds an OpenAI-compatible HTTP server inside your iOS
    app's own process — `http://127.0.0.1:38883/v1/chat/completions`,
    `/v1/embeddings`, `/v1/models`, SSE streaming, the standard error
    envelope. Any OpenAI client speaks to it (the OpenAI SDK, LangChain,
    autogen, crewai, instructor, Vercel AI SDK — anything).

    Backends: llama.cpp (Metal), Apple Foundation Models (iOS 26+),
    CoreML / ANE, MLX. Engine selected at runtime by device capability;
    your call site doesn't change.

    Why not just llama.cpp / MLX-Swift / Apple Foundation Models? Those
    are runtimes you wire up yourself — no HTTP surface, no agentic-
    framework interop, no resumable model downloader, no cross-device
    offload. DVAIBridge ships all of that as one library.

    Why not Ollama / LM Studio / llama-server? Those are SERVERS your
    END USERS install. DVAIBridge ships inside YOUR APP's binary —
    `pod install`, build, run. Zero setup for the user.

    Optional peer expansion: phone too slow? Pair with your Mac on the
    same Wi-Fi (mDNS) or across networks via a self-hostable WebSocket
    rendezvous — same OpenAI wire, transparent to consuming code.

    Same library, same OpenAI surface, also available for Android
    (Maven Central), Flutter (pub.dev), React Native + Capacitor +
    browser + Node (npm), and .NET MAUI / Avalonia / WinUI / Catalyst
    / desktop (NuGet). Cross-platform agentic apps stop being a
    per-platform porting exercise.

    Docs + architecture: https://bridge.deepvoiceai.co
  DESC
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
