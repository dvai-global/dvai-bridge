package co.deepvoiceai.bridge.shared.core.pairing

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.withTimeoutOrNull

/**
 * A single pending pairing request surfaced to the host UI. Compose
 * UIs collect these from [PairingPolicy.requests] and call either
 * [respond] or — equivalently — fall through to the default-deny
 * behaviour by ignoring the request until [PairingPolicy.approveOrFetch]
 * times out.
 */
class PairingRequest internal constructor(
    val peerDeviceId: String,
    val peerDeviceName: String,
    val via: PairingSource,
    private val response: CompletableDeferred<Boolean>,
) {
    /** Approve / deny. Idempotent — a second call is a no-op. */
    fun respond(approved: Boolean) {
        response.complete(approved)
    }

    /** True once the host UI has decided. */
    val isResolved: Boolean get() = response.isCompleted
}

/**
 * Pairing decision flow (Kotlin mirror of `PairingPolicy` from
 * `@westenets/dvai-bridge-core/src/pairing/policy.ts`).
 *
 * Coordinates the host-app UI (via [requests] `SharedFlow`) with the
 * persistent [PairingStore].
 *
 * Default behaviour with no UI subscriber: deny incoming pairings
 * after [requestTimeoutMs]. That's the safe fallback — apps that
 * haven't wired UI shouldn't accidentally accept random LAN devices.
 */
class PairingPolicy(
    private val store: PairingStore,
    /** Pairing TTL in days. Default 30. */
    private val expireAfterDays: Int = 30,
    /** Default-deny timeout when no UI subscriber answers. Default 60s. */
    private val requestTimeoutMs: Long = 60_000L,
) {
    // replay = 0 + buffer = 16: a request is dropped if no UI subscriber
    // is listening + the buffer is full. We rely on the suspendable
    // `approveOrFetch` to time out (default-deny) in that case rather
    // than replaying — a late subscriber should NOT auto-approve a
    // pairing request the user never saw a UI prompt for.
    private val _requests = MutableSharedFlow<PairingRequest>(
        replay = 0,
        extraBufferCapacity = 16,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /** Hot stream of incoming pairing requests for the host UI to collect. */
    val requests: SharedFlow<PairingRequest> = _requests.asSharedFlow()

    /**
     * Get an existing pairing, applying TTL expiry. Returns null if
     * the pairing is missing or expired (auto-cleans expired entries).
     */
    fun getActive(peerDeviceId: String): Pairing? {
        val existing = store.get(peerDeviceId) ?: return null
        val ttlMs = expireAfterDays.toLong() * 24L * 60L * 60L * 1000L
        if (System.currentTimeMillis() - existing.lastUsedAt > ttlMs) {
            store.remove(peerDeviceId)
            return null
        }
        return existing
    }

    /**
     * Process an incoming pairing request. If we already have an
     * active pairing for this peer, reuse it (and bump lastUsedAt).
     * Otherwise emit a [PairingRequest] on [requests] and wait up to
     * [requestTimeoutMs] for the UI to respond.
     *
     * Returns the resulting pairing on approval; throws
     * [PairingDeniedException] otherwise.
     */
    suspend fun approveOrFetch(
        peerDeviceId: String,
        peerDeviceName: String,
        via: PairingSource,
    ): Pairing {
        val existing = getActive(peerDeviceId)
        if (existing != null) {
            val touched = existing.copy(lastUsedAt = System.currentTimeMillis())
            store.set(touched)
            return touched
        }

        val deferred = CompletableDeferred<Boolean>()
        val req = PairingRequest(peerDeviceId, peerDeviceName, via, deferred)
        // tryEmit returns false if the buffer is full + no subscriber;
        // in that case treat it the same as "no UI listening" — deny.
        val emitted = _requests.tryEmit(req)
        if (!emitted) {
            throw PairingDeniedException(
                peerDeviceId,
                peerDeviceName,
                "no UI subscriber for pairing requests",
            )
        }
        val approved = withTimeoutOrNull(requestTimeoutMs) { deferred.await() } ?: false
        if (!approved) {
            throw PairingDeniedException(peerDeviceId, peerDeviceName, "denied or timed out")
        }
        val now = System.currentTimeMillis()
        val fresh = Pairing(
            peerDeviceId = peerDeviceId,
            peerDeviceName = peerDeviceName,
            pairingKey = PairingHandshake.generatePairingKey(),
            pairedAt = now,
            lastUsedAt = now,
            via = via,
        )
        store.set(fresh)
        return fresh
    }

    /** Mark a pairing as used (bumps lastUsedAt). */
    fun touch(peerDeviceId: String) {
        val existing = store.get(peerDeviceId) ?: return
        store.set(existing.copy(lastUsedAt = System.currentTimeMillis()))
    }

    /** Forget a pairing — host UI surfaces this as "revoke". */
    fun revoke(peerDeviceId: String) {
        store.remove(peerDeviceId)
    }
}

/** Thrown by [PairingPolicy.approveOrFetch] when the user denies / times out. */
class PairingDeniedException(
    val peerDeviceId: String,
    val peerDeviceName: String,
    reason: String,
) : Exception("[DVAI/pairing] denied: $peerDeviceName ($peerDeviceId): $reason")
