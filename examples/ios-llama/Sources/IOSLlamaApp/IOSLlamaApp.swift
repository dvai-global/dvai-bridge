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
            let server = try await DVAIBridge.shared.start(.init(
                backend: .llama,
                modelPath: download.path,
                gpuLayers: gpuLayers,
                contextSize: 1024
            ))

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
