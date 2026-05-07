import Foundation

/// Coordinates the host-app's pairing-request UI with the persistent
/// `PairingStore`. Mirrors `packages/dvai-bridge-core/src/pairing/policy.ts`.
///
/// The host app consumes the request stream via
/// `DVAIBridge.shared.pairingRequests`. If nothing is consuming the
/// stream when a request comes in, the policy denies — same safe
/// fallback as the JS side's default-deny.
public actor PairingPolicy {
    /// Default time the policy waits for the host app to respond to a
    /// `PairingRequest` before defaulting to deny. 30 seconds is the
    /// same magnitude as a typical OS permission prompt — long enough
    /// for the user to read + decide, short enough that an unattended
    /// device doesn't leak approval to a malicious peer.
    public static let defaultResponseTimeoutSeconds: Double = 30

    private let store: PairingStore
    private let expireAfterDays: Int
    private let responseTimeoutSeconds: Double
    private let continuation: AsyncStream<PairingRequest>.Continuation
    /// AsyncStream of pairing requests. Lifecycle-bound to this policy
    /// instance; finishes when `shutdown()` is called.
    public nonisolated let requestStream: AsyncStream<PairingRequest>

    public init(
        store: PairingStore,
        expireAfterDays: Int = 30,
        responseTimeoutSeconds: Double = PairingPolicy.defaultResponseTimeoutSeconds
    ) {
        self.store = store
        self.expireAfterDays = expireAfterDays
        self.responseTimeoutSeconds = responseTimeoutSeconds
        var savedContinuation: AsyncStream<PairingRequest>.Continuation!
        self.requestStream = AsyncStream<PairingRequest> { c in
            savedContinuation = c
        }
        self.continuation = savedContinuation
    }

    /// Active (non-expired) pairing for this peer, or nil.
    public func getActive(peerDeviceId: String) async -> Pairing? {
        guard let existing = await store.get(peerDeviceId) else { return nil }
        let ttlMs = Int64(expireAfterDays) * 24 * 60 * 60 * 1000
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if nowMs - existing.lastUsedAt > ttlMs {
            try? await store.remove(peerDeviceId)
            return nil
        }
        return existing
    }

    /// Process an incoming pairing request. If we already have an
    /// active pairing for this peer, reuse it (and bump lastUsedAt).
    /// Otherwise yield a `PairingRequest` to the host-app stream and
    /// await their decision.
    public func approveOrFetch(
        peerDeviceId: String,
        peerDeviceName: String,
        via: Pairing.Via
    ) async throws -> Pairing {
        if var existing = await getActive(peerDeviceId: peerDeviceId) {
            existing.lastUsedAt = Int64(Date().timeIntervalSince1970 * 1000)
            try await store.set(existing)
            return existing
        }

        let approved = await requestApproval(
            peerDeviceId: peerDeviceId,
            peerDeviceName: peerDeviceName,
            via: via
        )
        if !approved {
            throw DVAIBridgeError.configurationInvalid(
                reason: "[DVAI/pairing] denied: peer \(peerDeviceId) (\(peerDeviceName))"
            )
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let pairing = Pairing(
            peerDeviceId: peerDeviceId,
            peerDeviceName: peerDeviceName,
            pairingKey: PairingHandshake.generatePairingKey(),
            pairedAt: nowMs,
            lastUsedAt: nowMs,
            via: via
        )
        try await store.set(pairing)
        return pairing
    }

    /// Bump lastUsedAt for an existing pairing.
    public func touch(peerDeviceId: String) async throws {
        guard var existing = await store.get(peerDeviceId) else { return }
        existing.lastUsedAt = Int64(Date().timeIntervalSince1970 * 1000)
        try await store.set(existing)
    }

    public func revoke(peerDeviceId: String) async throws {
        try await store.remove(peerDeviceId)
    }

    /// Tear down the request stream. Called on `DVAIBridge.shared.stop()`.
    public func shutdown() {
        continuation.finish()
    }

    /// Surface a request to the host app and await their respond(:)
    /// call. If the host doesn't respond within
    /// `responseTimeoutSeconds`, the request defaults to deny — same
    /// safe fallback as the JS side when no `onPairingRequest` callback
    /// is supplied.
    private func requestApproval(
        peerDeviceId: String,
        peerDeviceName: String,
        via: Pairing.Via
    ) async -> Bool {
        // Race the host-app response against a timeout.
        return await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            let req = PairingRequest(
                peerDeviceId: peerDeviceId,
                peerDeviceName: peerDeviceName,
                via: via
            )
            let yieldResult = continuation.yield(req)
            switch yieldResult {
            case .enqueued:
                break
            case .terminated, .dropped:
                // Stream is gone or buffer dropped the value — deny.
                req.cancelWithDeny()
                return false
            @unknown default:
                req.cancelWithDeny()
                return false
            }
            // Consumer task: await the host's respond() call.
            group.addTask {
                await req.awaitResponse()
            }
            // Timeout task: if host hasn't responded in time, deny.
            let timeoutSeconds = self.responseTimeoutSeconds
            group.addTask {
                let nanos = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                req.cancelWithDeny()
                return false
            }
            // First completion wins.
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
