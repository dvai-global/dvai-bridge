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
 * @param hardwareMinimum      v3.2 — hard floor for any local inference, in tok/s.
 *                             Below this, the device is "too weak"; the SDK
 *                             aborts start() and (optionally) calls
 *                             [onHardwareTooWeak] so the host can show a
 *                             system popup. Default 3.0.
 * @param onHardwareTooWeak    v3.2 — host hook fired when the precheck
 *                             classifies the device as too-weak. Use to surface
 *                             a platform-native AlertDialog. The SDK still
 *                             throws afterward so start() fails in a
 *                             structured way (DVAIBridgeError.HardwareTooWeak).
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
    val hardwareMinimum: Double = 3.0,
    val onHardwareTooWeak: ((HardwareTooWeakInfo) -> Unit)? = null,
    val rendezvousUrl: String? = null,
    val knownPeers: List<Peer> = emptyList(),
    val onPairingRequest: (suspend (Peer) -> Boolean)? = null,
    val onOffload: ((Peer) -> Unit)? = null,
)

/** Detail surfaced to [OffloadConfig.onHardwareTooWeak]. */
data class HardwareTooWeakInfo(
    val tokPerSec: Double,
    val hardwareMinimum: Double,
    val reason: String,
)
