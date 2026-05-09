// examples/ios-offload-dogfood/Sources/IOSOffloadDogfoodApp/IOSOffloadDogfoodApp.swift
//
// Minimum-viable iOS SwiftUI app dogfooding the v3.2 outgoing-offload
// path. Pairs with a DVAI Hub on the LAN, sends a streaming chat
// completion, and renders each SSE chunk with its arrival timestamp
// so streaming behavior is visible to the eye.
//
// Architecture:
//   - DVAIBridge.shared.start(StartOptions(offload: enabled, minLocalCapability: 999))
//     → forces offload-only mode (no local backend, only the proxy).
//   - DVAIBridge.shared.pairingRequests() → AsyncStream<PairingRequest>;
//     when the Hub initiates pairing the UI shows approve/deny.
//   - DVAIBridge.shared.discoveryEvents() → live peer-discovery stream.
//   - "Send chat" → OpenAI Swift SDK against server.baseUrl ⇒ proxy
//     decides offload ⇒ HMAC-signed POST to Hub ⇒ Hub serves the
//     completion ⇒ SSE chunks arrive incrementally.

import SwiftUI
import DVAIBridge
import OpenAI

@main
struct IOSOffloadDogfoodApp: App {
    var body: some Scene {
        WindowGroup {
            DogfoodView()
        }
    }
}

/// Single chunk's text + when it arrived (wall clock relative to
/// start of the stream). Visible streaming → distinct timestamps.
struct ChunkEvent: Identifiable, Hashable {
    let id = UUID()
    let chunk: String
    let elapsedMs: Int
}

@MainActor
final class DogfoodModel: ObservableObject {
    @Published var serverBaseUrl: String? = nil
    @Published var status: String = "Idle — tap Start"
    /// Live MDNSPeer objects so we can pass them to `initiatePairing`.
    /// Keyed by `deviceId` so peer-down events remove the right entry.
    @Published var discoveredPeers: [MDNSPeer] = []
    @Published var pairings: [String] = []
    @Published var pendingPairing: PairingRequest? = nil
    @Published var chunks: [ChunkEvent] = []
    @Published var isStarted = false
    @Published var isStreaming = false
    @Published var isPairing = false

    private var pairingObserverTask: Task<Void, Never>? = nil
    private var discoveryObserverTask: Task<Void, Never>? = nil

    /// Default prompt. Long enough that streaming is visible (the
    /// model emits tokens over ~2-5s); short enough that tests stay
    /// snappy.
    let defaultPrompt =
        "Tell me a 3-sentence story about a curious cat that befriends a robot."

    func start() async {
        do {
            status = "Starting bridge in offload-only mode…"
            // minLocalCapability: 999.0 forces precheck → .offloadOnly
            // on every device. The SDK skips backend init and brings
            // up only the OffloadProxy + OffloadRuntime.
            // Use `.llama` explicitly. `.auto` would fail BackendSelector
            // on iOS < 26 because it has no `modelPath` to infer from
            // (auto-resolution falls through to `.foundation` only on
            // iOS 26+). In offload-only mode the inner backend start
            // is skipped anyway — the only thing the BackendKind feeds
            // is the synthetic `BoundServer.backend` field.
            let server = try await DVAIBridge.shared.start(StartOptions(
                config: DVAIBridgeConfig(backend: .llama),
                offload: OffloadConfig(
                    enabled: true,
                    discoverLAN: true,
                    minLocalCapability: 999.0
                )
            ))
            self.serverBaseUrl = server.baseUrl
            self.isStarted = true
            self.status = "Listening on \(server.baseUrl). Pair from the Hub."

            startObservers()
        } catch {
            self.status = "Start failed: \(error.localizedDescription)"
        }
    }

    func stop() async {
        pairingObserverTask?.cancel()
        discoveryObserverTask?.cancel()
        pairingObserverTask = nil
        discoveryObserverTask = nil
        try? await DVAIBridge.shared.stop()
        isStarted = false
        serverBaseUrl = nil
        status = "Stopped."
    }

    private func startObservers() {
        // Live peer-discovery stream. `discoveryEvents()` and
        // `pairingRequests()` are actor-isolated methods on the
        // `DVAIBridge` actor, so each call needs an `await` to hop
        // into the actor before grabbing the AsyncStream.
        discoveryObserverTask = Task { [weak self] in
            let stream = await DVAIBridge.shared.discoveryEvents()
            for await event in stream {
                guard let self else { return }
                await MainActor.run {
                    switch event {
                    case .peerUp(let peer):
                        // De-dupe by deviceId. NWBrowser fires peerUp
                        // repeatedly when TXT records change, so we
                        // index by stable id and replace.
                        if let idx = self.discoveredPeers.firstIndex(where: { $0.deviceId == peer.deviceId }) {
                            self.discoveredPeers[idx] = peer
                        } else {
                            self.discoveredPeers.append(peer)
                        }
                    case .peerDown(let deviceId):
                        self.discoveredPeers.removeAll { $0.deviceId == deviceId }
                    case .error(let msg):
                        self.status = "Discovery error: \(msg)"
                    }
                }
            }
        }
        // Incoming pairing requests — surface to the UI for
        // approve/deny.
        pairingObserverTask = Task { [weak self] in
            let stream = await DVAIBridge.shared.pairingRequests()
            for await req in stream {
                guard let self else { return }
                await MainActor.run {
                    self.pendingPairing = req
                    self.status = "Pairing request from \(req.peerDeviceName) — approve?"
                }
            }
        }
    }

    func approvePending() {
        guard let req = pendingPairing else { return }
        req.respond(approved: true)
        pairings.append("\(req.peerDeviceName) (\(req.peerDeviceId))")
        pendingPairing = nil
        status = "Paired with \(req.peerDeviceName). Ready to chat."
    }

    func denyPending() {
        pendingPairing?.respond(approved: false)
        pendingPairing = nil
        status = "Pairing denied."
    }

    /// Initiate a LAN handshake against the first discovered peer.
    /// The peer's UI surfaces an approval prompt; on approve, we
    /// receive the pairing key + persist it via the SDK.
    func pairWithFirstPeer() async {
        guard let peer = discoveredPeers.first else {
            status = "No peers discovered yet."
            return
        }
        isPairing = true
        defer { isPairing = false }
        status = "Pairing with \(peer.deviceName) at \(peer.baseUrl)…"
        do {
            let pairing = try await DVAIBridge.shared.initiatePairing(with: peer)
            pairings.append("\(pairing.peerDeviceName) (\(pairing.peerDeviceId))")
            status = "Paired with \(pairing.peerDeviceName). Ready to chat."
        } catch {
            status = "Pairing failed: \(error.localizedDescription)"
        }
    }

    func sendChat() async {
        guard let baseUrlStr = serverBaseUrl,
              let url = URL(string: baseUrlStr) else {
            status = "No bridge running."
            return
        }
        chunks = []
        isStreaming = true
        defer { isStreaming = false }

        let host = url.host ?? "127.0.0.1"
        let port = url.port ?? 38883
        let openAI = OpenAI(configuration: .init(
            token: "sk-local",
            host: host,
            port: port,
            scheme: "http",
            basePath: "/v1"
        ))

        status = "Streaming via offload proxy → Hub…"
        let startTs = Date()
        do {
            for try await chunk in openAI.chatsStream(query: .init(
                messages: [.user(.init(content: .string(defaultPrompt)))],
                model: "local",
                maxCompletionTokens: 200,
                temperature: 0.7
            )) {
                if let delta = chunk.choices.first?.delta.content {
                    let elapsedMs = Int(Date().timeIntervalSince(startTs) * 1000)
                    await MainActor.run {
                        self.chunks.append(ChunkEvent(chunk: delta, elapsedMs: elapsedMs))
                    }
                }
            }
            status = "Done. \(chunks.count) chunks, total \(chunks.last?.elapsedMs ?? 0) ms."
        } catch {
            status = "Stream failed: \(error.localizedDescription)"
        }
    }
}

struct DogfoodView: View {
    @StateObject private var model = DogfoodModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        Text("DVAI offload dogfood")
                            .font(.title2).bold()
                        Text(model.status)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    if let baseUrl = model.serverBaseUrl {
                        Text("Bridge URL: \(baseUrl)")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        if !model.isStarted {
                            Button("Start (offload-only)") { Task { await model.start() } }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Stop") { Task { await model.stop() } }
                                .buttonStyle(.bordered)
                        }
                        Button(model.isPairing ? "Pairing…" : "Pair with Hub") {
                            Task { await model.pairWithFirstPeer() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.isStarted || model.isPairing || model.discoveredPeers.isEmpty)
                        Button("Send chat") { Task { await model.sendChat() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.isStarted || model.isStreaming)
                    }

                    sectionHeader("Pairings")
                    if model.pairings.isEmpty {
                        Text("None yet — pair from the Hub on Mac.")
                            .font(.footnote).foregroundColor(.secondary)
                    } else {
                        ForEach(model.pairings, id: \.self) { p in
                            Text("• \(p)").font(.caption.monospaced())
                        }
                    }

                    sectionHeader("Discovered peers (mDNS)")
                    if model.discoveredPeers.isEmpty {
                        Text("Waiting for peers…")
                            .font(.footnote).foregroundColor(.secondary)
                    } else {
                        ForEach(model.discoveredPeers, id: \.deviceId) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("• \(p.deviceName)").font(.caption).bold()
                                Text("  \(p.baseUrl) — v\(p.dvaiVersion)")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }

                    sectionHeader("Chunks (streaming arrival times)")
                    if model.chunks.isEmpty {
                        Text("No completion yet.")
                            .font(.footnote).foregroundColor(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.chunks) { ev in
                                HStack(alignment: .top) {
                                    Text("\(ev.elapsedMs) ms")
                                        .font(.caption.monospaced())
                                        .frame(width: 60, alignment: .trailing)
                                        .foregroundColor(.secondary)
                                    Text(ev.chunk)
                                        .font(.caption)
                                }
                            }
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                .padding()
            }
            .navigationTitle("DVAI dogfood")
            .alert(
                item: Binding<PairingAlert?>(
                    get: {
                        model.pendingPairing.map {
                            PairingAlert(peerName: $0.peerDeviceName)
                        }
                    },
                    set: { _ in /* updates flow through model */ }
                )
            ) { alert in
                Alert(
                    title: Text("Pair with \(alert.peerName)?"),
                    message: Text("The Hub on \(alert.peerName) wants to pair with this device for offloaded inference."),
                    primaryButton: .default(Text("Approve")) { model.approvePending() },
                    secondaryButton: .destructive(Text("Deny")) { model.denyPending() }
                )
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 8)
    }
}

private struct PairingAlert: Identifiable {
    let id = UUID()
    let peerName: String
}
