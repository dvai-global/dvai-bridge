import Foundation

/// Coordinates the host-app's pairing-request UI with the persistent
/// `PairingStore`. Mirrors `packages/dvai-bridge-core/src/pairing/policy.ts`.
///
/// The host app consumes the request stream via
/// `DVAIBridge.shared.pairingRequests`. If nothing is consuming the
/// stream when a request comes in, the policy denies — same safe
/// fallback as the JS side's default-deny.
public actor PairingPolicy {
    private let store: PairingStore
    private let expireAfterDays: Int
    private let continuation: AsyncStream<PairingRequest>.Continuation
    /// AsyncStream of pairing requests. Lifecycle-bound to this policy
    /// instance; finishes when `shutdown()` is called.
    public nonisolated let requestStream: AsyncStream<PairingRequest>

    public init(store: PairingStore, expireAfterDays: Int = 30) {
        self.store = store
        self.expireAfterDays = expireAfterDays
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
    /// call. If no consumer is attached to the stream, the
    /// `PairingRequest`'s deinit fallback resumes the continuation
    /// with `false`.
    private func requestApproval(
        peerDeviceId: String,
        peerDeviceName: String,
        via: Pairing.Via
    ) async -> Bool {
        return await withCheckedContinuation { (responseCont: CheckedContinuation<Bool, Never>) in
            let req = PairingRequest(
                peerDeviceId: peerDeviceId,
                peerDeviceName: peerDeviceName,
                via: via,
                continuation: responseCont
            )
            let result = continuation.yield(req)
            switch result {
            case .terminated, .dropped:
                req.respond(approved: false)
            case .enqueued:
                break
            @unknown default:
                req.respond(approved: false)
            }
        }
    }
}
