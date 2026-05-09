import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if !COCOAPODS
import DVAILlamaCore
#endif
#if !COCOAPODS
import DVAIFoundationCore
#endif
#if !COCOAPODS
import DVAICoreMLCore
#endif
#if !COCOAPODS
import DVAIMLXCore
#endif

/// The iOS SDK entry-point. Use the `shared` singleton or construct an instance
/// for test isolation. All methods are async-throws and dispatch to the active
/// backend's PluginState under the hood. Capacitor-free: no Capacitor headers
/// are imported anywhere.
public actor DVAIBridge {
    public static let shared = DVAIBridge()

    /// Active backend handle. The CoreML state is stored as `Any` so this
    /// enum itself doesn't need an `@available` gate (the package's macOS
    /// floor is .v14 but `CoreMLPluginState` requires macOS 15). All access
    /// to the CoreML state happens inside `if #available(macOS 15.0, *)`.
    private enum BackendInstance {
        case llama(PluginState)
        #if !COCOAPODS
        // Foundation backend uses Apple's `FoundationModels` (iOS 26+),
        // whose import emits implicit autolink directives for private
        // frameworks (`SwiftUICore`, `UIUtilities`, `CoreAudioTypes`)
        // that non-Apple products cannot link directly. Under SwiftPM
        // the consumer's app target IS an allowed client of those
        // frameworks, so the link succeeds; under CocoaPods the link
        // happens inside the pod's framework target, which isn't.
        // Excluded here; selecting `.foundation` at runtime under a
        // CocoaPods build throws DVAIBridgeError.backendUnavailable.
        case foundation(FoundationPluginState)
        #endif
        case coreml(Any)
        #if !COCOAPODS
        // MLX backend uses mlx-swift-lm which depends on Apple's MLX
        // Swift framework. Same single-module-CocoaPods autolink concern
        // as Foundation; gated SwiftPM-only.
        case mlx(MLXPluginState)
        #endif
    }

    private var active: BackendInstance?
    private var activeKind: BackendKind?
    private var activeBaseUrl: String?
    private var offloadRuntime: Any?  // type-erased; gated by availability
    /// v3.2 — pre-routing proxy in front of the native backend when
    /// offload is enabled. Owns the public `BoundServer.baseUrl`.
    private var offloadProxy: Any?  // OffloadProxy; type-erased for availability
    /// v3.2 — set true when the precheck classified this device as
    /// `tooWeak` or `offloadOnly`. In that mode no model is loaded;
    /// the proxy stands alone and forwards every request to a peer.
    public private(set) var offloadOnlyMode: Bool = false
    private let downloader = ModelDownloader()
    internal let progressBroadcaster = ProgressBroadcaster()

    public init() {}

    // MARK: - v3.2 — Hardware assessment (data, not UI)

    /// v3.2 — pre-init hardware assessment.
    ///
    /// Returns a JSON-serializable description of how this device would
    /// handle local inference, BEFORE any model download/load. The SDK
    /// itself never shows UI for hardware decisions — consumer apps
    /// call this and decide their own UX based on the returned `mode`:
    ///
    ///   - `.ok`           → device can comfortably run the model
    ///                       locally; `start()` proceeds normally.
    ///   - `.offloadOnly`  → device can run but slowly (below
    ///                       `OffloadConfig.minLocalCapability`);
    ///                       `start()` skips the model load and routes
    ///                       every request to a paired peer.
    ///   - `.tooWeak`      → device is below the hardware floor (3
    ///                       tok/s by default); `start()` ALSO skips
    ///                       the model load. Consumers typically bail
    ///                       rather than even calling `start()`.
    ///
    /// The result is `Codable` so it round-trips cleanly through
    /// Capacitor / React Native / Pigeon bridges as JSON.
    public nonisolated func assessHardware(
        hardwareMinimum: Double = 3.0,
        minLocalCapability: Double = 10.0
    ) -> HardwareAssessment {
        let result = CapabilityPrecheck.assess(
            thresholds: CapabilityPrecheck.Thresholds(
                hardwareMinimum: hardwareMinimum,
                minLocalCapability: minLocalCapability
            )
        )
        return HardwareAssessment(from: result)
    }

    // MARK: - Lifecycle

    /// v3.0+ surface: start with `StartOptions` (carries optional
    /// `OffloadConfig`).
    ///
    /// v3.2 lifecycle:
    ///   - if `offload.enabled == true`, run the pre-init capability
    ///     gate (`assessHardware`) before any backend init.
    ///   - if the precheck returns `tooWeak` / `offloadOnly`, skip
    ///     backend init entirely (`offloadOnlyMode = true`); only the
    ///     OffloadRuntime + OffloadProxy come up. Every chat request
    ///     forwards to a paired peer.
    ///   - otherwise the inner `start(_ config:)` runs normally with
    ///     the backend on `httpBasePort + 100` (internal). The
    ///     OffloadProxy binds the user-facing `httpBasePort` and
    ///     decides per-request whether to forward locally or to a
    ///     peer.
    ///
    /// For v2.x backwards compat (no offload): the inner
    /// `start(_ config:)` overload behaves exactly as before.
    public func start(_ options: StartOptions) async throws -> BoundServer {
        offloadOnlyMode = false

        let isOffloadEnabled = options.offload?.enabled == true
        if isOffloadEnabled {
            let assessment = assessHardware(
                hardwareMinimum: 3.0,
                minLocalCapability: options.offload!.minLocalCapability
            )
            offloadOnlyMode = (assessment.mode == .tooWeak || assessment.mode == .offloadOnly)
            progressBroadcaster.emit(ProgressEvent(
                phase: .load,
                message: "[DVAI/precheck] \(assessment.mode.rawValue): \(assessment.reason)"
            ))
        }

        // Determine the backend's internal port. When the proxy is in
        // front, shift the backend off the user-facing port to avoid
        // collision: backend at httpBasePort + 100, proxy at httpBasePort.
        let userPort = options.config.httpBasePort
        let backendOpts: DVAIBridgeConfig
        if isOffloadEnabled && !offloadOnlyMode {
            backendOpts = options.config.with(httpBasePort: userPort + 100)
        } else {
            backendOpts = options.config
        }

        let backendServer: BoundServer? = offloadOnlyMode
            ? nil
            : try await start(backendOpts)

        // Bring up offload runtime + proxy when offload is enabled.
        if isOffloadEnabled, let offload = options.offload {
            if #available(iOS 14.0, macOS 11.0, *) {
                let runtime = try OffloadRuntime(config: offload)
                // OffloadRuntime.start expects a BoundServer for the
                // advertiser's `port`. Use a synthetic one in offload-only
                // mode (port = userPort, the proxy's port).
                let resolvedBackend = try BackendSelector.resolve(options.config.backend, config: options.config)
                let serverForRuntime = backendServer ?? BoundServer(
                    baseUrl: "http://127.0.0.1:\(userPort)",
                    port: userPort,
                    backend: resolvedBackend,
                    modelId: ""
                )
                try await runtime.start(
                    boundServer: serverForRuntime,
                    libraryVersion: DVAIBridgeVersion.current
                )
                self.offloadRuntime = runtime

                // Spin up the OffloadProxy in front of the backend.
                let deviceId = (try? await runtime.deviceIDStore.get()) ?? "unknown"
                let proxy = OffloadProxy(
                    backendBaseUrl: backendServer?.baseUrl,
                    offloadConfig: offload,
                    pairingPolicy: runtime.pairingPolicy,
                    peerProvider: { [weak runtime] in
                        guard let runtime else { return [] }
                        return await runtime.discovery.peers()
                    },
                    appId: "co.deepvoiceai.dvai-bridge",
                    selfDeviceId: deviceId
                )
                let boundProxyPort = try await proxy.start(basePort: userPort, maxAttempts: 16)
                self.offloadProxy = proxy

                let proxyServer = BoundServer(
                    baseUrl: "http://127.0.0.1:\(boundProxyPort)",
                    port: boundProxyPort,
                    backend: resolvedBackend,
                    modelId: backendServer?.modelId ?? ""
                )
                self.activeBaseUrl = proxyServer.baseUrl
                if active == nil {
                    activeKind = proxyServer.backend
                }
                return proxyServer
            }
        }

        return backendServer!
    }

    public func start(_ config: DVAIBridgeConfig) async throws -> BoundServer {
        if let activeBaseUrl, let activeKind {
            throw DVAIBridgeError.alreadyStarted(currentBackend: activeKind, baseUrl: activeBaseUrl)
        }

        let resolved = try BackendSelector.resolve(config.backend, config: config)
        let opts = config.toCoreOpts()

        let result: [String: Any]
        let backend: BackendInstance

        progressBroadcaster.emit(ProgressEvent(phase: .load))

        switch resolved {
        case .auto:
            // BackendSelector.resolve never returns .auto; keep the compiler happy
            throw DVAIBridgeError.configurationInvalid(reason: "BackendSelector returned .auto unexpectedly")
        case .llama:
            let state = PluginState()
            do {
                result = try await state.start(opts: opts)
            } catch {
                progressBroadcaster.emit(ProgressEvent(phase: .error, message: error.localizedDescription))
                throw DVAIBridgeError.modelLoadFailed(reason: error.localizedDescription)
            }
            backend = .llama(state)
        case .foundation:
            #if !COCOAPODS
            let state = FoundationPluginState()
            do {
                result = try await state.start(opts: opts)
            } catch {
                progressBroadcaster.emit(ProgressEvent(phase: .error, message: error.localizedDescription))
                throw DVAIBridgeError.backendError(underlying: error.localizedDescription)
            }
            backend = .foundation(state)
            #else
            throw DVAIBridgeError.backendUnavailable(
                .foundation,
                reason: "Foundation Models backend is not available in CocoaPods builds of dvai-bridge — Apple's FoundationModels framework triggers private-framework autolink directives that CocoaPods consumers cannot link. Use SwiftPM if your app needs the Foundation backend, or use .llama or .coreml instead."
            )
            #endif
        case .coreml:
            // iOS 18.1 floor of this package already satisfies CoreMLPluginState's
            // iOS 18.0 requirement, but macOS 14 (the package floor) does not
            // satisfy its macOS 15.0 requirement — gate explicitly.
            if #available(macOS 15.0, *) {
                let state = CoreMLPluginState()
                do {
                    result = try await state.start(opts: opts)
                } catch {
                    progressBroadcaster.emit(ProgressEvent(phase: .error, message: error.localizedDescription))
                    throw DVAIBridgeError.backendUnavailable(.coreml, reason: error.localizedDescription)
                }
                backend = .coreml(state)
            } else {
                throw DVAIBridgeError.backendUnavailable(.coreml, reason: "Requires macOS 15+")
            }
        case .mlx:
            #if !COCOAPODS
            let state = MLXPluginState()
            do {
                result = try await state.start(opts: opts)
            } catch {
                progressBroadcaster.emit(ProgressEvent(phase: .error, message: error.localizedDescription))
                throw DVAIBridgeError.backendUnavailable(.mlx, reason: error.localizedDescription)
            }
            backend = .mlx(state)
            #else
            throw DVAIBridgeError.backendUnavailable(
                .mlx,
                reason: "MLX backend is not available in CocoaPods builds of dvai-bridge — mlx-swift-lm's transitive dependencies don't publish CocoaPods specs. Use SwiftPM if your app needs the MLX backend, or use .llama or .coreml instead."
            )
            #endif
        }

        let server = try BoundServer(coreResult: result, backend: resolved)
        self.active = backend
        self.activeKind = resolved
        self.activeBaseUrl = server.baseUrl

        progressBroadcaster.emit(ProgressEvent(phase: .ready))

        let serverCopy = server
        await MainActor.run {
            DVAIBridgeReactiveStateRegistry.shared.state(for: self).didStart(serverCopy)
        }
        return server
    }

    public func stop() async throws {
        // v3.2 — tear down the proxy first so consumer requests stop
        // arriving before we drop the backend; then stop the offload
        // runtime (discovery + advertiser) before the backend dies.
        if #available(iOS 14.0, macOS 11.0, *) {
            if let proxy = offloadProxy as? OffloadProxy {
                await proxy.stop()
            }
        }
        offloadProxy = nil
        offloadOnlyMode = false

        // Tear down the offload runtime — it depends on the bound
        // server being up while we stop discovery cleanly.
        if #available(iOS 14.0, macOS 11.0, *) {
            if let runtime = offloadRuntime as? OffloadRuntime {
                await runtime.stop()
            }
        }
        offloadRuntime = nil

        guard let backend = active else {
            return  // idempotent
        }
        do {
            switch backend {
            case .llama(let state):
                try await state.stop()
            #if !COCOAPODS
            case .foundation(let state):
                try await state.stop()
            #endif
            case .coreml(let any):
                // Always gated — macOS 14 can never have stored a coreml state
                // here (start() rejects it), so this branch is unreachable on
                // pre-15 macOS, but the availability check is required by the
                // type system.
                if #available(macOS 15.0, *) {
                    if let state = any as? CoreMLPluginState {
                        try await state.stop()
                    }
                }
            #if !COCOAPODS
            case .mlx(let state):
                try await state.stop()
            #endif
            }
        } catch {
            // Even if stop() throws, clear state — caller can't usefully retry
            self.active = nil
            self.activeKind = nil
            self.activeBaseUrl = nil
            await MainActor.run {
                DVAIBridgeReactiveStateRegistry.shared.state(for: self).didStop()
            }
            throw DVAIBridgeError.backendError(underlying: error.localizedDescription)
        }
        self.active = nil
        self.activeKind = nil
        self.activeBaseUrl = nil
        await MainActor.run {
            DVAIBridgeReactiveStateRegistry.shared.state(for: self).didStop()
        }
    }

    // MARK: - Status

    public struct StatusInfo: Sendable, Equatable {
        public let running: Bool
        public let backend: BackendKind?
        public let baseUrl: String?
    }

    public func status() -> StatusInfo {
        StatusInfo(
            running: active != nil,
            backend: activeKind,
            baseUrl: activeBaseUrl
        )
    }

    // MARK: - Progress observation

    public nonisolated var progressPublisher: AnyPublisher<ProgressEvent, Never> {
        progressBroadcaster.publisher
    }

    public nonisolated var progressStream: AsyncStream<ProgressEvent> {
        progressBroadcaster.makeStream()
    }

    @discardableResult
    public nonisolated func addProgressListener(
        _ cb: @escaping @Sendable (ProgressEvent) -> Void
    ) -> CancellationToken {
        progressBroadcaster.addCallback(cb)
    }

    // MARK: - Model management (delegates to ModelDownloader)

    public struct DownloadOptions: Sendable {
        public var url: URL
        public var sha256: String
        public var destFilename: String?
        public var headers: [String: String]
        public init(url: URL, sha256: String, destFilename: String? = nil, headers: [String: String] = [:]) {
            self.url = url
            self.sha256 = sha256
            self.destFilename = destFilename
            self.headers = headers
        }
    }

    public struct DownloadResult: Sendable, Equatable {
        public let path: String
        public let cached: Bool
        public init(path: String, cached: Bool) {
            self.path = path
            self.cached = cached
        }
    }

    public func downloadModel(_ opts: DownloadOptions) async throws -> DownloadResult {
        let dest = opts.destFilename ?? opts.url.lastPathComponent
        progressBroadcaster.emit(ProgressEvent(phase: .download))
        do {
            let coreResult = try await downloader.downloadModel(
                url: opts.url,
                expectedSha256: opts.sha256,
                destFilename: dest,
                headers: opts.headers,
                onProgress: { [weak self] (received: Int64, total: Int64?) in
                    let percent: Double? = total.flatMap { $0 > 0 ? (Double(received) / Double($0)) * 100.0 : nil }
                    self?.progressBroadcaster.emit(ProgressEvent(
                        phase: .download,
                        bytesReceived: received,
                        bytesTotal: total,
                        percent: percent
                    ))
                }
            )
            progressBroadcaster.emit(ProgressEvent(phase: .verify))
            return DownloadResult(path: coreResult.path, cached: coreResult.cached)
        } catch {
            progressBroadcaster.emit(ProgressEvent(phase: .error, message: error.localizedDescription))
            if case ModelDownloader.DownloadError.checksumMismatch = error {
                throw DVAIBridgeError.checksumMismatch
            }
            throw DVAIBridgeError.downloadFailed(reason: error.localizedDescription)
        }
    }

    public func listCachedModels() async throws -> [CachedModelInfoSwift] {
        try await downloader.listCachedModels()
    }

    public func deleteCachedModel(filename: String) async throws {
        try await downloader.deleteCachedModel(filename: filename)
    }

    public func cacheDir() async throws -> String {
        try await downloader.cacheDirPath()
    }

    // MARK: - Offload (v3.0)

    /// AsyncStream of incoming pairing requests. The host app awaits
    /// `for await req in await DVAIBridge.shared.pairingRequests()` and
    /// calls `req.respond(approved:)` to approve or deny each one.
    ///
    /// Returns an empty (immediately-finished) stream when offload isn't
    /// enabled or hasn't been started yet.
    public func pairingRequests() -> AsyncStream<PairingRequest> {
        if #available(iOS 14.0, macOS 11.0, *) {
            if let runtime = self.offloadRuntime as? OffloadRuntime {
                return runtime.pairingRequestStream()
            }
        }
        return Self.emptyStream()
    }

    /// AsyncStream of LAN-discovery events (peer-up / peer-down).
    /// Empty if offload isn't enabled.
    @available(iOS 14.0, macOS 11.0, *)
    public func discoveryEvents() -> AsyncStream<NWBrowserDiscovery.Event> {
        if let runtime = self.offloadRuntime as? OffloadRuntime {
            return runtime.discoveryEventStream()
        }
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    /// Stable per-install device ID for THIS device. Generated on
    /// first call and persisted under
    /// `<Application Support>/dvai-bridge/device-id`. Used by host
    /// apps to filter the iPhone's own `_dvai-bridge._tcp`
    /// advertisement out of `discoveryEvents()` (NWBrowser surfaces
    /// the local device's own service alongside remote peers — match
    /// against this id to drop the self-loop).
    ///
    /// - Throws if offload isn't enabled / start() hasn't run.
    @available(iOS 14.0, macOS 11.0, *)
    public func deviceId() async throws -> String {
        guard let runtime = self.offloadRuntime as? OffloadRuntime else {
            throw DVAIBridgeError.configurationInvalid(reason:
                "deviceId requires offload to be enabled and start() to have been called.")
        }
        return try await runtime.deviceIDStore.get()
    }

    /// v3.2.1 — initiate a LAN pairing handshake against a discovered
    /// peer. POSTs `/v1/dvai/handshake` to `peer.baseUrl` with our
    /// device identity in the body; on the peer's approval, persists
    /// the returned pairing key to our local `PairingStore` so future
    /// offload requests to that peer get HMAC-signed.
    ///
    /// Wire-compatible with the TS-side `handleHandshake` in
    /// `packages/dvai-bridge-core/src/handlers/dvai/index.ts` AND the
    /// matching iOS-side handler that ships with this release in
    /// `OffloadProxy.handleHandshakeRequest`.
    ///
    /// - Throws `DVAIBridgeError.configurationInvalid` if offload
    ///   isn't started, or the peer rejects the handshake (HTTP 4xx),
    ///   or the response body is malformed.
    /// - Throws underlying URLSession errors on transport failure.
    @available(iOS 14.0, macOS 11.0, *)
    public func initiatePairing(with peer: MDNSPeer) async throws -> Pairing {
        guard let runtime = self.offloadRuntime as? OffloadRuntime else {
            throw DVAIBridgeError.configurationInvalid(reason:
                "initiatePairing requires offload to be enabled and start() to have been called.")
        }

        // Identity of THIS device — what we send to the peer so it
        // knows who's asking. The peer's UI surfaces these strings
        // in its approval prompt.
        let selfDeviceId = try await runtime.deviceIDStore.get()
        let selfDeviceName = await Self.resolveSelfName()

        // peer.baseUrl already ends in `/v1` (NWBrowserDiscovery
        // synthesises it as `<scheme>://<host>:<port>/v1`). Strip
        // that trailing segment before appending `/v1/dvai/handshake`,
        // otherwise the URL becomes `…/v1/v1/dvai/handshake` and the
        // peer 404s.
        let trimmedBase = peer.baseUrl.hasSuffix("/v1")
            ? String(peer.baseUrl.dropLast("/v1".count))
            : peer.baseUrl
        guard let url = URL(string: trimmedBase + "/v1/dvai/handshake") else {
            throw DVAIBridgeError.configurationInvalid(reason:
                "[DVAI/pairing] could not construct handshake URL from baseUrl=\(peer.baseUrl)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyDict: [String: Any] = [
            "peerDeviceId": selfDeviceId,
            "peerDeviceName": selfDeviceName,
            "via": "lan-handshake",
            "appId": "co.deepvoiceai.dvai-bridge",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
        req.timeoutInterval = 60.0  // matches the iOS pairing-policy default

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw DVAIBridgeError.configurationInvalid(reason: "[DVAI/pairing] non-HTTP response from peer")
        }
        if http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? "<no body>"
            throw DVAIBridgeError.configurationInvalid(reason:
                "[DVAI/pairing] peer rejected handshake (HTTP \(http.statusCode)): \(detail)")
        }

        // Response shape mirrors the TS handler:
        //   { paired: true, pairedAt, via, pairingKey, peerDeviceId }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["paired"] as? Bool == true,
              let pairingKey = json["pairingKey"] as? String,
              let peerDeviceIdResp = json["peerDeviceId"] as? String,
              let pairedAt = (json["pairedAt"] as? Int64)
                ?? (json["pairedAt"] as? Int).map(Int64.init) else {
            throw DVAIBridgeError.configurationInvalid(reason:
                "[DVAI/pairing] malformed handshake response from peer")
        }
        let viaRaw = (json["via"] as? String) ?? "lan-handshake"
        let via = Pairing.Via(rawValue: viaRaw) ?? .lanHandshake

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let pairing = Pairing(
            peerDeviceId: peerDeviceIdResp,
            peerDeviceName: peer.deviceName,
            pairingKey: pairingKey,
            pairedAt: pairedAt,
            lastUsedAt: nowMs,
            via: via
        )
        try await runtime.pairingStore.set(pairing)
        return pairing
    }

    /// Best-effort device-name lookup used by `initiatePairing`. iOS
    /// blocks `UIDevice.current.name` off the main thread; fall back
    /// to the host name when off-main.
    private static func resolveSelfName() async -> String {
        #if canImport(UIKit) && !os(macOS)
        return await MainActor.run { UIDevice.current.name }
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    private static func emptyStream<T: Sendable>() -> AsyncStream<T> {
        AsyncStream<T> { continuation in
            continuation.finish()
        }
    }

    /// Test-only accessor for the current offload runtime, if any.
    /// Returns nil when offload isn't enabled or `start()` hasn't run.
    @available(iOS 14.0, macOS 11.0, *)
    internal func _testOffloadRuntime() -> OffloadRuntime? {
        offloadRuntime as? OffloadRuntime
    }
}

/// Library SemVer constant — keep in sync with the package's published
/// version. Used by the mDNS advertiser TXT record.
public enum DVAIBridgeVersion {
    public static let current = "3.0.0-rc1"
}
