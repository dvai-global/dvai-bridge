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

    // v3.2.1 — distributed-inference scaffold. If `assessHardware()`
    // reports the device is too slow for local Foundation Models
    // (e.g. iOS 25 or older devices that can't run iOS 26's
    // on-device LLM), the example routes the same chat completion
    // through a paired DVAI Hub on the LAN. Set `hubUrl` below to
    // the Hub's address — the Hub UI's Status tab shows it. Leave
    // it nil to disable offload.
    private static let hubUrl: String? = nil  // e.g. "http://192.168.1.42:38883"

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
        isRunning = true
        defer { isRunning = false }
        output = ""
        do {
            // v3.2.1 — pre-init capability gate. For Foundation Models
            // the constraint is iOS 26+ runtime AND adequate hardware.
            // If we're on iOS 25 or earlier we can still demo by
            // offloading to a paired Hub (which can serve via any
            // adapter — Ollama / vLLM / llama-server / etc.).
            let assessment = DVAIBridge.shared.assessHardware()
            status = "Hardware: \(assessment.mode.rawValue) (\(String(format: "%.1f", assessment.tokPerSec)) tok/s est)"
            try? await Task.sleep(nanoseconds: 500_000_000)

            let isOldOS: Bool
            if #available(iOS 26.0, macOS 26.0, *) { isOldOS = false } else { isOldOS = true }
            let mustOffload = (assessment.mode != .ok) || isOldOS

            let server: BoundServer
            if mustOffload {
                if assessment.mode == .tooWeak {
                    status = "Device too weak for inference: \(assessment.reason)"
                    return
                }
                guard let hubUrl = Self.hubUrl else {
                    status = isOldOS
                        ? "iOS 26+ required for Foundation Models. Set Self.hubUrl to offload to a Hub."
                        : "Device too slow for local inference. Set Self.hubUrl to a paired DVAI Hub."
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
                // No modelPath — Foundation Models manages the on-device LLM.
                status = "Starting Foundation Models…"
                server = try await DVAIBridge.shared.start(.init(
                    backend: .foundation
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
