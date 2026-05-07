package co.deepvoiceai.bridge.shared.core.offload

import co.deepvoiceai.bridge.shared.core.discovery.Peer

/**
 * Configuration for distributed inference / device offload (Kotlin
 * mirror of the TS `OffloadConfig` in
 * `@westenets/dvai-bridge-core/src/offload/types.ts`).
 *
 * Offload is opt-in: pass an `OffloadConfig(enabled = true)` to
 * `StartOptions.offload` to turn it on. Default is null = behave
 * exactly like v2.x.
 *
 * @param enabled              Master switch. Default false.
 * @param discoverLAN          Run mDNS / NsdManager discovery for LAN peers. Default true.
 * @param minLocalCapability   Below this tok/s, look for a peer. Default 10.0.
 * @param rendezvousUrl        Optional rendezvous-server URL — enables internet path.
 * @param knownPeers           Optional pre-known peers (skip discovery for them).
 * @param onPairingRequest     Suspending callback returning approve/deny for incoming
 *                             pairings. If null, [PairingPolicy.requests] Flow is the
 *                             only path; if both are absent, default-deny applies.
 *                             Mirrors the JS callback shape.
 * @param onOffload            Diagnostic callback when a request is offloaded. Optional.
 */
data class OffloadConfig(
    val enabled: Boolean = false,
    val discoverLAN: Boolean = true,
    val minLocalCapability: Double = 10.0,
    val rendezvousUrl: String? = null,
    val knownPeers: List<Peer> = emptyList(),
    val onPairingRequest: (suspend (Peer) -> Boolean)? = null,
    val onOffload: ((Peer) -> Unit)? = null,
)
