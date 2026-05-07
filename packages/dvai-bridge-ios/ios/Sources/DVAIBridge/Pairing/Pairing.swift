import Foundation

/// A "pairing" is an authenticated trust relationship between two
/// devices, established once via the handshake flow then reused for
/// all subsequent offload requests via HMAC-signed headers. Mirrors
/// the TS shape in `packages/dvai-bridge-core/src/pairing/types.ts`.
public struct Pairing: Sendable, Equatable, Codable, Hashable {
    public enum Via: String, Sendable, Codable, Hashable {
        case lanHandshake = "lan-handshake"
        case rendezvousQR = "rendezvous-qr"
    }

    /// Stable per-install device ID of the peer.
    public let peerDeviceId: String
    /// Friendly name for the user UI.
    public let peerDeviceName: String
    /// Shared 256-bit pairing key (base64-url encoded). Used for HMAC.
    public let pairingKey: String
    /// When the pairing was first established (unix ms).
    public let pairedAt: Int64
    /// Last time this pairing was used (unix ms).
    public var lastUsedAt: Int64
    /// Pairing source — informational.
    public let via: Via

    public init(
        peerDeviceId: String,
        peerDeviceName: String,
        pairingKey: String,
        pairedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        lastUsedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        via: Via = .lanHandshake
    ) {
        self.peerDeviceId = peerDeviceId
        self.peerDeviceName = peerDeviceName
        self.pairingKey = pairingKey
        self.pairedAt = pairedAt
        self.lastUsedAt = lastUsedAt
        self.via = via
    }
}

/// Surfaced to the host app as an item in `DVAIBridge.shared.pairingRequests`.
/// The host app decides approve/deny, then calls `respond(approved:)`.
public final class PairingRequest: Sendable {
    public let peerDeviceId: String
    public let peerDeviceName: String
    public let via: Pairing.Via
    private let continuation: CheckedContinuation<Bool, Never>
    private let respondedFlag: ResponseFlag

    public init(
        peerDeviceId: String,
        peerDeviceName: String,
        via: Pairing.Via,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        self.peerDeviceId = peerDeviceId
        self.peerDeviceName = peerDeviceName
        self.via = via
        self.continuation = continuation
        self.respondedFlag = ResponseFlag()
    }

    public func respond(approved: Bool) {
        guard respondedFlag.markResponded() else { return }
        continuation.resume(returning: approved)
    }

    deinit {
        // If the host app never responded, default to deny so the
        // continuation always resumes (safer than leaking).
        if respondedFlag.markResponded() {
            continuation.resume(returning: false)
        }
    }

    private final class ResponseFlag: @unchecked Sendable {
        private var responded = false
        private let lock = NSLock()
        func markResponded() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if responded { return false }
            responded = true
            return true
        }
    }
}
