import Foundation

/// Lifecycle progress event emitted during start(), downloadModel(), and
/// related long-running operations. Mirrors the existing TS / Capacitor
/// `ProgressEvent` shape so the iOS SDK reads identically to the JS API.
public struct ProgressEvent: Sendable, Equatable, Codable {
    public enum Phase: String, Sendable, Codable {
        case download
        case verify
        case load
        case ready
        case error
    }

    public let phase: Phase
    public let bytesReceived: Int64?
    public let bytesTotal: Int64?
    public let percent: Double?
    public let message: String?

    public init(
        phase: Phase,
        bytesReceived: Int64? = nil,
        bytesTotal: Int64? = nil,
        percent: Double? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.bytesReceived = bytesReceived
        self.bytesTotal = bytesTotal
        self.percent = percent
        self.message = message
    }
}
