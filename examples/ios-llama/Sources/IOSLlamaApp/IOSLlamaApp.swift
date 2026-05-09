// examples/ios-llama/Sources/IOSLlamaApp/IOSLlamaApp.swift
//
// Minimum-viable iOS SwiftUI app demonstrating dvai-bridge with the
// llama.cpp backend. Single screen: a "Load + Ask" button that
// downloads a GGUF model on first run, boots the local OpenAI-compatible
// server, and streams a chat completion using the MacPaw OpenAI Swift SDK.
//
// The point is to show "standard agent code, local server" — the only
// dvai-bridge-specific lines are `DVAIBridge.shared.start(...)` and the
// model download. Everything else is the OpenAI Swift SDK against a
// custom `host`.

import SwiftUI
import DVAIBridge
import OpenAI

@main
struct IOSLlamaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var state = DVAIBridge.shared.reactive
    @State private var output: String = ""
    @State private var status: String = "Idle"
    @State private var isRunning = false

    // Bartowski's Llama-3.2-1B-Instruct GGUF (Q4_K_M ~800 MB).
    // First run downloads + caches; subsequent runs hit the cache.
    private static let modelUrl = URL(string:
        "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    )!
    // sha256 of the canonical Q4_K_M file. Verified at download time.
    private static let modelSha256 =
        "26f2c2c1f9dd54ba91b4a1f4c5b5b50fe28a4e3ac48be44a39b5e7e9a8e8bb52"

    // v3.2.1 — distributed-inference scaffold. If `assessHardware()`
    // reports the device is too slow for local inference, the example
    // routes the same chat completion through a paired DVAI Hub on
    // the LAN instead of downloading + loading the 800 MB GGUF
    // locally. Set `hubUrl` below to the Hub's address (the Hub UI's
    // Status tab shows it). Leave it nil to disable offload — the
    // device will fail with `tooWeak` if it can't run llama.cpp
    // locally.
    private static let hubUrl: String? = nil  // e.g. "http://192.168.1.42:38883"

    var body: some View {
        VStack(spacing: 16) {
            Text("dvai-bridge · iOS · llama.cpp")
                .font(.title2).bold()
            Text(status)
                .font(.footnote)
                .foregroundColor(.secondary)
            ScrollView {
                Text(output.isEmpty ? "Tap 'Load + Ask' to begin." : output)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
            }
            Button(action: { Task { await loadAndAsk() } }) {
                Text(isRunning ? "Working…" : "Load + Ask")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isRunning ? Color.gray : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .disabled(isRunning)
        }
        .padding()
    }

    private func loadAndAsk() async {
        isRunning = true
        defer { isRunning = false }
        output = ""
        do {
            // v3.2.1 — pre-init capability gate. Decide local-vs-offload
            // BEFORE we touch the 800 MB GGUF download. tok/s heuristic
            // is documented in `Capability/CapabilityPrecheck.swift`.
            //   - .ok           → strong device, run locally (fast path)
            //   - .offloadOnly  → too slow for comfortable local
            //                     inference; use the Hub via OffloadConfig
            //   - .tooWeak      → can't even meaningfully offload-stream;
            //                     show the user a friendly stop sign
            let assessment = DVAIBridge.shared.assessHardware()
            status = "Hardware: \(assessment.mode.rawValue) (\(String(format: "%.1f", assessment.tokPerSec)) tok/s est)"
            try? await Task.sleep(nanoseconds: 500_000_000)  // let the user read it

            let server: BoundServer
            if assessment.mode == .tooWeak {
                status = "Device too weak for local inference: \(assessment.reason)"
                return
            } else if assessment.mode == .offloadOnly {
                guard let hubUrl = Self.hubUrl else {
                    status = "Device too slow for local inference. Set Self.hubUrl to a paired DVAI Hub."
                    return
                }
                // Skip backend init entirely; the proxy will route the
                // chat completion through the paired Hub. The OpenAI
                // client below stays unchanged.
                status = "Starting in offload-only mode → \(hubUrl)…"
                server = try await DVAIBridge.shared.start(StartOptions(
                    config: DVAIBridgeConfig(backend: .llama),
                    offload: OffloadConfig(
                        enabled: true,
                        discoverLAN: true,
                        minLocalCapability: 999.0  // force offload-only
                    )
                ))
                // Pair with the Hub so subsequent forwards carry HMAC.
                let hubPeer = MDNSPeer(
                    deviceId: "manual:\(hubUrl)",
                    deviceName: "DVAI Hub",
                    dvaiVersion: "unknown",
                    baseUrl: hubUrl.hasSuffix("/v1") ? hubUrl : hubUrl + "/v1",
                    via: .static
                )
                _ = try await DVAIBridge.shared.initiatePairing(with: hubPeer)
                status = "Paired with Hub. Streaming…"
            } else {
                // 1. Download (if not cached) — sha256-verified.
                status = "Downloading model…"
                let download = try await DVAIBridge.shared.downloadModel(.init(
                    url: Self.modelUrl,
                    sha256: Self.modelSha256
                ))

                // 2. Start the bridge with the llama backend. gpuLayers=0 on
                //    simulator (no Metal), 99 on device.
                #if targetEnvironment(simulator)
                let gpuLayers = 0
                #else
                let gpuLayers = 99
                #endif
                status = "Loading model…"
                server = try await DVAIBridge.shared.start(.init(
                    backend: .llama,
                    modelPath: download.path,
                    gpuLayers: gpuLayers,
                    contextSize: 1024
                ))
            }

            // 3. Hand the OpenAI SDK the BoundServer.baseUrl. baseUrl is
            //    `http://127.0.0.1:<port>/v1` — split into host+port+path
            //    for the MacPaw configuration.
            status = "Streaming…"
            let url = URL(string: server.baseUrl)!
            let host = url.host ?? "127.0.0.1"
            let port = url.port ?? 38883
            let openAI = OpenAI(configuration: .init(
                token: "sk-local",   // unused; the local server doesn't auth
                host: host,
                port: port,
                scheme: "http",
                basePath: "/v1"
            ))

            // Model id is forwarded verbatim through the OffloadProxy
            // to the Hub's engine adapter. `llama3.2:latest` matches
            // the Ollama tag the dogfood Mac has installed; it's also
            // a meaningful identifier for the local llama.cpp backend
            // (which doesn't strictly validate the id).
            for try await chunk in openAI.chatsStream(query: .init(
                messages: [.user(.init(content: .string("Tell me a one-line joke.")))],
                model: "llama3.2:latest",
                maxCompletionTokens: 64,
                temperature: 0
            )) {
                if let delta = chunk.choices.first?.delta.content {
                    output += delta
                }
            }
            status = "Done. Backend: \(state.currentBackend?.rawValue ?? "?") · port \(server.port)"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }
}
