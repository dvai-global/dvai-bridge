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
            // 1. Boot the bridge with backend: .mlx + the HF id as
            //    modelPath. mlx-swift-lm handles the download + cache.
            status = "Loading MLX checkpoint…"
            let server = try await DVAIBridge.shared.start(.init(
                backend: .mlx,
                modelPath: Self.mlxModelId,
                contextSize: 1024
            ))

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
                model: "local",
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
