import Foundation

/// Swift-side `Peer` value mirroring the TypeScript `Peer` shape in
/// `packages/dvai-bridge-core/src/discovery/types.ts`. Used by the
/// iOS-native discovery layer (`NWBrowserDiscovery`) and surfaced to
/// host apps via the offload module.
public struct MDNSPeer: Sendable, Equatable, Codable, Hashable {
    /// Stable per-install device ID of the peer.
    public let deviceId: String
    /// Human-readable hint (iOS device name, hostname, etc.).
    public let deviceName: String
    /// Library SemVer the peer is running.
    public let dvaiVersion: String
    /// OpenAI-compatible base URL the peer's local server exposes.
    public let baseUrl: String
    /// Models the peer claims to have loaded right now.
    public let loadedModels: [String]
    /// Peer-reported capability map: { modelId → tok/s }.
    public let capability: [String: Double]
    /// Discovery source — useful for diagnostics.
    public let via: Via
    /// Whether the peer's URL uses TLS.
    public let secure: Bool
    /// Last-seen unix ms — discovery sources update this.
    public let lastSeenAt: Int64

    public enum Via: String, Sendable, Codable, Hashable {
        case mdns
        case `static`
        case rendezvous
        case custom
    }

    public init(
        deviceId: String,
        deviceName: String,
        dvaiVersion: String,
        baseUrl: String,
        loadedModels: [String] = [],
        capability: [String: Double] = [:],
        via: Via = .mdns,
        secure: Bool = false,
        lastSeenAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.dvaiVersion = dvaiVersion
        self.baseUrl = baseUrl
        self.loadedModels = loadedModels
        self.capability = capability
        self.via = via
        self.secure = secure
        self.lastSeenAt = lastSeenAt
    }
}

/// Service-type advertised on mDNS for dvai-bridge instances. Mirrors the
/// `MDNS_SERVICE_TYPE` constant in `discovery/types.ts`.
public enum DVAIBridgeMDNS {
    public static let serviceType = "_dvai-bridge._tcp"
    public static let serviceDomain = "local."
    /// Full DNS-SD service-type form used by some APIs.
    public static let serviceTypeFull = "_dvai-bridge._tcp.local"
}
