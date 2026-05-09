// examples/ios-mlx/Sources/IOSMLXApp/IOSMLXApp.swift
//
// SwiftUI app demonstrating dvai-bridge with the MLX backend
// (Apple Silicon GPU/ANE via mlx-swift-lm).
//
// MLX consumes a HuggingFace MLX-converted checkpoint id directly —
// no GGUF, no .mlpackage, no manual download. The HF Hub cache is
// managed by mlx-swift-lm itself.
//
// Apple Silicon-only at runtime; the iOS Simulator on Intel Macs has
// no MLX device. SwiftPM-only.

import SwiftUI
import DVAIBridge
import OpenAI

@main
struct IOSMLXApp: App {
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

    /// HuggingFace MLX-community id for Llama-3.2-3B-Instruct, 4-bit
    /// MLX-converted. mlx-swift-lm downloads + caches it on first run.
    private static let mlxModelId = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    // v3.2.1 — distributed-inference scaffold. MLX is Apple Silicon
    // only. On Intel Macs / iPhone simulator on Intel hosts / non-AS
    // devices, route through a paired DVAI Hub on the LAN. Set
    // `hubUrl` to enable.
    private static let hubUrl: String? = nil  // e.g. "http://192.168.1.42:38883"

    var body: some View {
        VStack(spacing: 16) {
            Text("dvai-bridge · iOS · MLX")
                .font(.title2).bold()
            Text(status)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
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
            Text("Apple Silicon only.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private func loadAndAsk() async {
        isRunning = true
        defer { isRunning = false }
        output = ""
        do {
            // v3.2.1 — pre-init capability gate. MLX is Apple-Silicon
            // only at runtime; precheck branches to offload otherwise.
            let assessment = DVAIBridge.shared.assessHardware()
            status = "Hardware: \(assessment.mode.rawValue) (\(String(format: "%.1f", assessment.tokPerSec)) tok/s est)"
            try? await Task.sleep(nanoseconds: 500_000_000)

            let server: BoundServer
            if assessment.mode != .ok {
                if assessment.mode == .tooWeak {
                    status = "Device too weak for inference: \(assessment.reason)"
                    return
                }
                guard let hubUrl = Self.hubUrl else {
                    status = "Device too slow for local MLX. Set Self.hubUrl to a paired DVAI Hub."
                    return
                }
                status = "Starting in offload-only mode → \(hubUrl)…"
                server = try await DVAIBridge.shared.start(StartOptions(
                    config: DVAIBridgeConfig(backend: .llama),  // backend is moot in offload-only
                    offload: OffloadConfig(
                        enabled: true,
                        discoverLAN: true,
                        minLocalCapability: 999.0  // force offload-only
                    )
                ))
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
                // 1. Boot the bridge with backend: .mlx + the HF id as
                //    modelPath. mlx-swift-lm handles the download + cache.
                status = "Loading MLX checkpoint…"
                server = try await DVAIBridge.shared.start(.init(
                    backend: .mlx,
                    modelPath: Self.mlxModelId,
                    contextSize: 1024
                ))
            }

            status = "Streaming…"
            let url = URL(string: server.baseUrl)!
            let host = url.host ?? "127.0.0.1"
            let port = url.port ?? 38883
            let openAI = OpenAI(configuration: .init(
                token: "sk-local",
                host: host,
                port: port,
                scheme: "http",
                basePath: "/v1"
            ))

            for try await chunk in openAI.chatsStream(query: .init(
                messages: [.user(.init(content: .string("Tell me a one-line joke.")))],
                model: "llama3.2:latest",  // forwarded verbatim to backend / Hub
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
