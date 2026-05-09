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
import os.log

/// Subsystem for `os_log` so the auto-loop's events are visible via
/// `xcrun simctl spawn booted log stream --predicate
/// 'subsystem == "co.deepvoiceai.dvai.dogfood"'` from the Mac. Means
/// the SSH-driven test loop can read what the app is doing without
/// any UI scraping.
private let dogfoodLog = Logger(subsystem: "co.deepvoiceai.dvai.dogfood", category: "loop")

/// One line in the in-app event log. Mirrors what `os_log` emits.
struct LogEvent: Identifiable {
    let id = UUID()
    let ts: Date
    let level: Level
    let message: String

    enum Level { case info, warn, error }
}

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
    /// Manual Hub URL. The DVAI Hub doesn't advertise on mDNS — it
    /// only listens for inbound handshakes — so the iOS app can't
    /// auto-discover it via NWBrowser. User pastes the Mac's LAN
    /// address here, e.g. `http://192.168.1.42:38883`. Used by
    /// `pairWithManualHub()` to construct a synthetic MDNSPeer for
    /// `initiatePairing(with:)`.
    /// Hardcoded fallback for the dogfood — the Mac running the
    /// DVAI Hub on the test LAN. Auto-mode uses this directly so
    /// the simulator can run without UI input. Manual entry still
    /// overrides via the TextField when running on a real device.
    static let defaultHubUrl = "http://192.168.0.112:38883"

    @Published var manualHubUrl: String = DogfoodModel.defaultHubUrl
    /// Model id sent in the chat-completion request body. Forwarded
    /// verbatim to the Hub which forwards verbatim to its engine
    /// adapter (Ollama / vLLM / etc.). Default matches the model
    /// the v3.2 dogfood Mac has installed (`ollama pull llama3.2`)
    /// — change this if your Hub is talking to a different engine.
    @Published var modelId: String = "llama3.2:latest"

    /// Auto-loop control — when true, the app drives the full
    /// start → pair → chat cycle on a timer with no user input. Runs
    /// on simulator launch so a remote operator (e.g. running tests
    /// over SSH) can iterate without poking the UI. Each iteration
    /// logs structured events to `eventLog` AND `os_log` (visible via
    /// `xcrun simctl spawn booted log stream`).
    @Published var autoMode: Bool = true
    /// Append-only log of high-level events (start, pair, chat, error).
    /// Bounded to the most recent 100 entries to keep SwiftUI happy.
    @Published var eventLog: [LogEvent] = []
    private var autoLoopTask: Task<Void, Never>? = nil
    private var autoIteration: Int = 0

    /// Our own deviceId, captured at start() so the discovery filter
    /// can drop self-advertisements (NWBrowser sees the iPhone's own
    /// `_dvai-bridge._tcp` advertisement on the loopback).
    private var selfDeviceId: String? = nil

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
            //
            // Bind the OffloadProxy on 38900 instead of the SDK default
            // 38883. The DVAI Hub also binds 38883 — when the iPhone
            // simulator runs on the SAME Mac as the Hub, both end up
            // on the same loopback. The kernel routes packets to the
            // more-specific `127.0.0.1:38883` listener (the sim's own
            // proxy) instead of the Hub's `*:38883` wildcard, so
            // requests targeted at `192.168.0.112:38883` (a local IP)
            // get intercepted by the sim's own proxy via lo0 and
            // never reach the Hub. Using a separate port avoids the
            // conflict regardless of how the OS routes local-IP
            // connections.
            let server = try await DVAIBridge.shared.start(StartOptions(
                config: DVAIBridgeConfig(backend: .llama, httpBasePort: 38900),
                offload: OffloadConfig(
                    enabled: true,
                    discoverLAN: true,
                    minLocalCapability: 999.0
                )
            ))
            self.serverBaseUrl = server.baseUrl
            self.isStarted = true
            // Capture our own deviceId so the discovery observer can
            // filter the local device's self-advertisement out of the
            // peer list (NWBrowser doesn't suppress it automatically).
            self.selfDeviceId = try? await DVAIBridge.shared.deviceId()
            self.status = "Listening on \(server.baseUrl). Discovering peers…"

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
                        // Filter out our own advertisement —
                        // NWBrowser surfaces the local device's
                        // `_dvai-bridge._tcp` service alongside
                        // remote peers, which would let the user
                        // accidentally try to pair the iPhone with
                        // itself.
                        if let myId = self.selfDeviceId, peer.deviceId == myId {
                            return
                        }
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

    /// Append to both the in-app log + os_log. The UI log ring is
    /// bounded to 100 lines so the SwiftUI list doesn't grow without
    /// bound during long auto-loop runs.
    func log(_ msg: String, _ level: LogEvent.Level = .info) {
        let ev = LogEvent(ts: Date(), level: level, message: msg)
        eventLog.append(ev)
        if eventLog.count > 100 { eventLog.removeFirst(eventLog.count - 100) }
        switch level {
        case .info: dogfoodLog.info("\(msg, privacy: .public)")
        case .warn: dogfoodLog.warning("\(msg, privacy: .public)")
        case .error: dogfoodLog.error("\(msg, privacy: .public)")
        }
    }

    /// Auto-mode driver. Idempotent: if the bridge is already running
    /// AND a pairing for the configured Hub already exists, skip the
    /// preamble and go straight to chat. Loops indefinitely with a
    /// 12-second cooldown between iterations so a remote operator
    /// can watch behaviour evolve via logs.
    func startAutoLoop() {
        guard autoLoopTask == nil else { return }
        log("auto-loop start: hub=\(manualHubUrl) model=\(modelId)")
        autoLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runAutoIteration()
                try? await Task.sleep(nanoseconds: 12 * 1_000_000_000)
            }
        }
    }

    func stopAutoLoop() {
        autoLoopTask?.cancel()
        autoLoopTask = nil
        log("auto-loop stopped")
    }

    private func runAutoIteration() async {
        autoIteration += 1
        let n = autoIteration
        log("─── iteration \(n) ───")

        // 1. Bring up the bridge if needed.
        if !isStarted {
            log("step1: starting bridge in offload-only mode")
            await start()
            if !isStarted {
                log("step1 FAILED: \(status)", .error)
                return
            }
            // Give discovery + advertise a moment to settle.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        } else {
            log("step1: bridge already running")
        }

        // 2. Pair if needed.
        if pairings.isEmpty {
            log("step2: pairing with \(manualHubUrl)")
            await pairWithManualHub()
            if pairings.isEmpty {
                log("step2 FAILED: \(status)", .error)
                return
            }
        } else {
            log("step2: already paired (\(pairings.count) entries)")
        }

        // 3. Send a chat completion + log timing/chunks.
        log("step3: sending chat to model=\(modelId)")
        let t0 = Date()
        await sendChat()
        let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
        if let first = chunks.first, let last = chunks.last {
            // ttfb = time to FIRST chunk; ttlb = time to LAST chunk.
            // For real streaming, ttfb << ttlb; for buffered transport,
            // ttfb ≈ ttlb (every chunk lands at the same moment).
            log("step3 OK: \(chunks.count) chunks, total \(elapsed) ms, ttfb=\(first.elapsedMs) ms, ttlb=\(last.elapsedMs) ms")
        } else {
            log("step3 FAILED: no chunks. status=\(status)", .error)
        }
    }

    /// Initiate a LAN handshake against the first discovered peer.
    /// The peer's UI surfaces an approval prompt; on approve, we
    /// receive the pairing key + persist it via the SDK.
    func pairWithFirstPeer() async {
        guard let peer = discoveredPeers.first else {
            status = "No peers discovered yet."
            return
        }
        await pair(with: peer)
    }

    /// Pair with a manually-entered Hub URL (DVAI Hub doesn't
    /// advertise on mDNS — it only listens — so the user pastes the
    /// Mac's LAN address). We synthesise an `MDNSPeer` carrying just
    /// the baseUrl + a placeholder deviceId; the peer's handshake
    /// response includes its real deviceId which is what gets
    /// persisted in `PairingStore`.
    func pairWithManualHub() async {
        let trimmed = manualHubUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.host != nil else {
            status = "Enter a valid Hub URL like http://192.168.1.42:38883"
            return
        }
        // Normalise: strip trailing slash, ensure /v1 suffix matches
        // the convention NWBrowserDiscovery uses for advertised peers.
        var normalised = trimmed
        if normalised.hasSuffix("/") { normalised.removeLast() }
        if !normalised.hasSuffix("/v1") { normalised += "/v1" }

        let synthetic = MDNSPeer(
            deviceId: "manual:\(normalised)",  // placeholder; peer's response carries the real one
            deviceName: "Hub@\(url.host ?? "manual")",
            dvaiVersion: "unknown",
            baseUrl: normalised,
            via: .static
        )
        await pair(with: synthetic)
    }

    private func pair(with peer: MDNSPeer) async {
        isPairing = true
        defer { isPairing = false }
        status = "Pairing with \(peer.deviceName) at \(peer.baseUrl)…"
        do {
            let pairing = try await DVAIBridge.shared.initiatePairing(with: peer)
            // De-dupe by content — re-pairing the same device replaces
            // the entry rather than appending a duplicate (the
            // PairingStore overwrites by deviceId; we mirror that in
            // the UI list so SwiftUI's `ForEach(id: \.self)` doesn't
            // hit the "duplicate ids" warning).
            let entry = "\(pairing.peerDeviceName) (\(pairing.peerDeviceId))"
            if let idx = pairings.firstIndex(where: { $0.contains(pairing.peerDeviceId) }) {
                pairings[idx] = entry
            } else {
                pairings.append(entry)
            }
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
                model: modelId,
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
                    // Auto-mode toggle + log panel (top so they're
                    // visible in screenshots taken by automation).
                    HStack {
                        Toggle("Auto-loop", isOn: $model.autoMode)
                            .toggleStyle(.switch)
                            .onChange(of: model.autoMode) { _, newVal in
                                if newVal { model.startAutoLoop() } else { model.stopAutoLoop() }
                            }
                        Spacer()
                    }
                    if !model.eventLog.isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(model.eventLog.suffix(20)) { ev in
                                Text(formatEvent(ev))
                                    .font(.caption2.monospaced())
                                    .foregroundColor(eventColor(ev.level))
                                    .lineLimit(1)
                            }
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(6)
                    }

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
                        Button("Send chat") { Task { await model.sendChat() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.isStarted || model.isStreaming)
                    }

                    sectionHeader("Model id")
                    Text("Forwarded verbatim to the Hub → its engine adapter (Ollama tag, vLLM model, etc.).")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("llama3.2:latest", text: $model.modelId)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    sectionHeader("Hub pairing")
                    Text("The DVAI Hub doesn't advertise on mDNS — paste its URL.")
                        .font(.caption).foregroundColor(.secondary)
                    HStack {
                        TextField("http://192.168.x.x:38883", text: $model.manualHubUrl)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button(model.isPairing ? "…" : "Pair") {
                            Task { await model.pairWithManualHub() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.isStarted || model.isPairing || model.manualHubUrl.isEmpty)
                    }
                    if !model.discoveredPeers.isEmpty {
                        Button(model.isPairing ? "Pairing…" : "Pair with first discovered peer") {
                            Task { await model.pairWithFirstPeer() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.isStarted || model.isPairing)
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
            .onAppear {
                // Kick off the auto-loop on first appearance. The
                // loop is idempotent — if the bridge already runs,
                // it skips start and goes straight to chat.
                if model.autoMode {
                    model.startAutoLoop()
                }
            }
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

    private func formatEvent(_ ev: LogEvent) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let prefix: String
        switch ev.level {
        case .info: prefix = " "
        case .warn: prefix = "!"
        case .error: prefix = "✗"
        }
        return "\(f.string(from: ev.ts)) \(prefix) \(ev.message)"
    }

    private func eventColor(_ level: LogEvent.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}

private struct PairingAlert: Identifiable {
    let id = UUID()
    let peerName: String
}
