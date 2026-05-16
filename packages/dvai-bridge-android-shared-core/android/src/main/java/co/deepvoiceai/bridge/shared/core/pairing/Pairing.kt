package co.deepvoiceai.bridge.shared.core.pairing

import kotlinx.serialization.Serializable

/**
 * Phase 3 — pairing types (Kotlin mirror of `Pairing` /
 * `HandshakeRequest` / `HandshakeResponse` from
 * `@dvai-bridge/core/src/pairing/types.ts`).
 *
 * A "pairing" is an authenticated trust relationship between two
 * devices established once via the handshake flow, then reused for
 * all subsequent offload requests via HMAC-signed headers.
 *
 * Pairings expire after [PairingPolicy] TTL (default 30 days) of
 * inactivity.
 */
@Serializable
data class Pairing(
    /** Stable per-install device ID of the peer. */
    val peerDeviceId: String,
    /** Friendly name for the user UI (revoke / re-pair). */
    val peerDeviceName: String,
    /** Shared 256-bit pairing key (base64-url encoded). Used for HMAC. */
    val pairingKey: String,
    /** When the pairing was first established. */
    val pairedAt: Long,
    /** Last time this pairing was used for an offload request. */
    val lastUsedAt: Long,
    /** Pairing source — informational. */
    val via: PairingSource,
)

@Serializable
enum class PairingSource {
    @kotlinx.serialization.SerialName("lan-handshake")
    LAN_HANDSHAKE,
    @kotlinx.serialization.SerialName("rendezvous-qr")
    RENDEZVOUS_QR,
}

@Serializable
data class HandshakeRequest(
    val originDeviceId: String,
    val originDeviceName: String,
    val originVersion: String,
    /** Initiator-side ephemeral nonce — included in the HMAC challenge. */
    val nonce: String,
)

@Serializable
data class HandshakeResponse(
    /** Approved? */
    val approved: Boolean,
    /** If approved, the shared pairing key (base64-url). */
    val pairingKey: String? = null,
    /** If denied, the reason for the diagnostic. */
    val reason: String? = null,
)
