import Foundation

/// Swift-side `CapabilityScore` mirroring the TypeScript shape in
/// `packages/dvai-bridge-core/src/capability/types.ts`. Persisted by
/// `CapabilityCache`.
public struct CapabilityScore: Sendable, Equatable, Codable, Hashable {
    /// Source of the estimate.
    public enum Source: String, Sendable, Codable, Hashable {
        case probe
        case heuristic
    }

    /// Model identifier this score applies to.
    public let modelId: String
    /// Stable per-install device identifier.
    public let deviceId: String
    /// Library SemVer at the time the score was measured.
    public let libraryVersion: String
    /// Estimated decode rate, tokens-per-second.
    public let tokPerSec: Double
    /// Source of the estimate.
    public let source: Source
    /// Unix milliseconds the score was measured / computed.
    public let measuredAt: Int64

    public init(
        modelId: String,
        deviceId: String,
        libraryVersion: String,
        tokPerSec: Double,
        source: Source = .heuristic,
        measuredAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.modelId = modelId
        self.deviceId = deviceId
        self.libraryVersion = libraryVersion
        self.tokPerSec = tokPerSec
        self.source = source
        self.measuredAt = measuredAt
    }
}

public struct CapabilityCacheKey: Sendable, Hashable {
    public let modelId: String
    public let libraryVersion: String

    public init(modelId: String, libraryVersion: String) {
        self.modelId = modelId
        self.libraryVersion = libraryVersion
    }
}
