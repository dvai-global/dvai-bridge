import Foundation

/// Per-instance offload configuration. Mirrors the TS-side
/// `OffloadConfig` in `packages/dvai-bridge-core/src/offload/types.ts`.
///
/// Default state: `enabled = false` — offload is opt-in at v3.0.
///
/// Set on `StartOptions(offload:)` when calling
/// `DVAIBridge.shared.start(_:)`.
public struct OffloadConfig: Sendable {
    /// Master switch. Default `false`; offload is opt-in at v3.0.
    public var enabled: Bool
    /// Run mDNS to discover LAN peers. Default `true` when enabled.
    public var discoverLAN: Bool
    /// Below this tok/s, look for a peer. Default 10.
    public var minLocalCapability: Double
    /// Optional rendezvous-server URL — enables internet path if set.
    public var rendezvousUrl: URL?
    /// Optional pre-known peers (skip discovery for these).
    public var knownPeers: [MDNSPeer]
    /// Pairing TTL in days. Default 30 — matches the JS-side default
    /// in `PairingPolicy`.
    public var expireAfterDays: Int

    public init(
        enabled: Bool = false,
        discoverLAN: Bool = true,
        minLocalCapability: Double = 10,
        rendezvousUrl: URL? = nil,
        knownPeers: [MDNSPeer] = [],
        expireAfterDays: Int = 30
    ) {
        self.enabled = enabled
        self.discoverLAN = discoverLAN
        self.minLocalCapability = minLocalCapability
        self.rendezvousUrl = rendezvousUrl
        self.knownPeers = knownPeers
        self.expireAfterDays = expireAfterDays
    }
}

/// Modern start-options surface that wraps `DVAIBridgeConfig` and adds
/// the `offload` knob. Both call sites are supported on
/// `DVAIBridge.shared.start(...)`:
///
///     try await DVAIBridge.shared.start(.init(backend: .auto, modelPath: "/x"))
///     try await DVAIBridge.shared.start(StartOptions(
///         backend: .auto,
///         modelPath: "/x",
///         offload: OffloadConfig(enabled: true, discoverLAN: true)
///     ))
///
/// Internally `StartOptions` decomposes into `(DVAIBridgeConfig, OffloadConfig?)`
/// so all existing tests + call sites that take a config keep working.
public struct StartOptions: Sendable {
    public var config: DVAIBridgeConfig
    public var offload: OffloadConfig?
    /// v3.2.2 — explicit path to the license `.jwt` file. Overrides the
    /// auto-discovery walk (Bundle resource, Documents, etc). The same
    /// .jwt format works across iOS / Android / .NET / RN / JS SDKs.
    public var licenseKeyPath: String?
    /// v3.2.2 — inline JWT license. Useful when the host app fetches
    /// the license over the network and wants to inject the result
    /// without touching disk. Wins over `licenseKeyPath` if both are set.
    public var licenseToken: String?

    public init(
        config: DVAIBridgeConfig,
        offload: OffloadConfig? = nil,
        licenseKeyPath: String? = nil,
        licenseToken: String? = nil
    ) {
        self.config = config
        self.offload = offload
        self.licenseKeyPath = licenseKeyPath
        self.licenseToken = licenseToken
    }

    /// Convenience initializer that mirrors the documented public
    /// surface in `docs/migration/v2.4-to-v3.0.md`.
    public init(
        backend: BackendKind = .auto,
        modelPath: String? = nil,
        mmprojPath: String? = nil,
        tokenizerPath: String? = nil,
        gpuLayers: Int = 99,
        contextSize: Int = 2048,
        threads: Int = 4,
        embeddingMode: Bool = false,
        httpBasePort: Int = 38883,
        httpMaxPortAttempts: Int = 16,
        corsOrigin: DVAIBridgeConfig.CORSOrigin = .wildcard,
        autoUnloadOnLowMemory: Bool = false,
        logLevel: String = "info",
        offload: OffloadConfig? = nil,
        licenseKeyPath: String? = nil,
        licenseToken: String? = nil
    ) {
        self.config = DVAIBridgeConfig(
            backend: backend,
            modelPath: modelPath,
            mmprojPath: mmprojPath,
            tokenizerPath: tokenizerPath,
            gpuLayers: gpuLayers,
            contextSize: contextSize,
            threads: threads,
            embeddingMode: embeddingMode,
            httpBasePort: httpBasePort,
            httpMaxPortAttempts: httpMaxPortAttempts,
            corsOrigin: corsOrigin,
            autoUnloadOnLowMemory: autoUnloadOnLowMemory,
            logLevel: logLevel
        )
        self.offload = offload
        self.licenseKeyPath = licenseKeyPath
        self.licenseToken = licenseToken
    }
}
