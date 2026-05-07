// examples/ios-foundation/Sources/IOSFoundationApp/IOSFoundationApp.swift
//
// SwiftUI app demonstrating dvai-bridge with the Apple Foundation Models
// backend. Requires iOS 26+ at runtime; the package's link-time floor is
// 18.1 because Apple's `FoundationModels` framework's symbols resolve
// at runtime against the iOS 26 SDK.
//
// No model download — Apple Intelligence manages the on-device model.
// Boot the bridge with `backend: .foundation` (no modelPath needed) and
// hit the local OpenAI-compatible endpoint with the OpenAI Swift SDK.

import SwiftUI
import DVAIBridge
import OpenAI

@main
struct IOSFoundationApp: App {
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

    var body: some View {
        VStack(spacing: 16) {
            Text("dvai-bridge · iOS · Foundation Models")
                .font(.title2).bold()
            Text(runtimeNoticeIfNeeded() ?? status)
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
        }
        .padding()
    }

    /// Returns a user-friendly hint when the runtime can't actually
    /// run the .foundation backend; nil otherwise (use `status`).
    private func runtimeNoticeIfNeeded() -> String? {
        if #available(iOS 26.0, macOS 26.0, *) {
            return nil
        }
        return "This example requires iOS 26+ at runtime. Foundation Models is managed by Apple Intelligence; no model download."
    }

    private func loadAndAsk() async {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            status = "Foundation Models requires iOS 26+; tap won't do anything on this OS."
            return
        }
        isRunning = true
        defer { isRunning = false }
        output = ""
        do {
            // No modelPath — Foundation Models manages the on-device LLM.
            status = "Starting Foundation Models…"
            let server = try await DVAIBridge.shared.start(.init(
                backend: .foundation
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
