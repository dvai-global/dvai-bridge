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

/// Surfaced to the host app as an item in the
/// `DVAIBridge.shared.pairingRequests()` AsyncStream. The host app
/// decides approve/deny, then calls `respond(approved:)`.
///
/// If the host doesn't call `respond(approved:)` within the policy's
/// timeout, the request defaults to deny — see `PairingPolicy`.
public final class PairingRequest: @unchecked Sendable {
    public let peerDeviceId: String
    public let peerDeviceName: String
    public let via: Pairing.Via

    private let lock = NSLock()
    private var responded = false
    private var pendingValue: Bool?
    /// Continuation used by the policy to await the host's respond.
    /// Lazily set when `awaitResponse()` is called the first time.
    private var awaitContinuation: CheckedContinuation<Bool, Never>?

    public init(
        peerDeviceId: String,
        peerDeviceName: String,
        via: Pairing.Via
    ) {
        self.peerDeviceId = peerDeviceId
        self.peerDeviceName = peerDeviceName
        self.via = via
    }

    /// Host-app entry point. Approve or deny the pairing.
    public func respond(approved: Bool) {
        lock.lock()
        if responded {
            lock.unlock()
            return
        }
        responded = true
        if let cont = awaitContinuation {
            awaitContinuation = nil
            lock.unlock()
            cont.resume(returning: approved)
        } else {
            // No one's awaiting yet — store the value for whoever
            // calls awaitResponse() next.
            pendingValue = approved
            lock.unlock()
        }
    }

    /// Internal — used by `PairingPolicy` to await the host response.
    /// Resumes when `respond(approved:)` is called or returns `false`
    /// when `cancelWithDeny()` is called.
    internal func awaitResponse() async -> Bool {
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if let stored = pendingValue {
                pendingValue = nil
                lock.unlock()
                cont.resume(returning: stored)
            } else if responded {
                lock.unlock()
                cont.resume(returning: false)
            } else {
                awaitContinuation = cont
                lock.unlock()
            }
        }
    }

    /// Internal — fast-path deny used by the policy on timeout / stream
    /// teardown / drop.
    internal func cancelWithDeny() {
        respond(approved: false)
    }
}
