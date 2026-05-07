package co.deepvoiceai.bridge.shared.core.discovery

import kotlinx.serialization.Serializable

/**
 * Phase 3 — peer discovery types (Kotlin mirror of the TS `Peer` shape
 * in `@westenets/dvai-bridge-core/src/discovery/types.ts`).
 *
 * A "peer" is another device running dvai-bridge that this device can
 * (potentially) offload inference requests to. Peers are surfaced by
 * one or more discovery sources — LAN mDNS via [NsdDiscovery], app-
 * supplied static lists, rendezvous-paired (internet), or a host-app
 * provided custom source.
 */
@Serializable
data class Peer(
    /** Stable per-install device ID of the peer. */
    val deviceId: String,
    /** Human-readable hint (Android device name, hostname, etc.). */
    val deviceName: String,
    /** Library SemVer the peer is running. */
    val dvaiVersion: String,
    /** OpenAI-compatible base URL the peer's local server exposes. */
    val baseUrl: String,
    /**
     * Models the peer claims to have loaded right now. Used to filter
     * peer eligibility — we only offload model X to a peer that already
     * has model X loaded (loading from scratch on the peer is fine but
     * defeats the latency win).
     */
    val loadedModels: List<String> = emptyList(),
    /**
     * Peer-reported capability map: { modelId → tok/s }. Treat as
     * advisory only; the offload decider re-probes a peer with a small
     * reachability+decode test before its first real offload request.
     */
    val capability: Map<String, Double> = emptyMap(),
    /** Discovery source — useful for diagnostics and structured-error responses. */
    val via: PeerSource,
    /** Whether the peer's URL uses TLS. */
    val secure: Boolean = false,
    /** Last-seen unix ms — discovery sources update this. */
    val lastSeenAt: Long = 0L,
)

@Serializable
enum class PeerSource {
    @kotlinx.serialization.SerialName("mdns")
    MDNS,
    @kotlinx.serialization.SerialName("static")
    STATIC,
    @kotlinx.serialization.SerialName("rendezvous")
    RENDEZVOUS,
    @kotlinx.serialization.SerialName("custom")
    CUSTOM,
}

/**
 * Service-type advertised on mDNS for dvai-bridge instances. Mirrors
 * `MDNS_SERVICE_TYPE` from the TS reference. Note that NsdManager
 * uses the short form `_dvai-bridge._tcp` (no trailing `.local` —
 * the platform appends it).
 */
const val DVAI_NSD_SERVICE_TYPE: String = "_dvai-bridge._tcp"

/**
 * Field names in the TXT record advertised + parsed by the LAN
 * discovery layer. Single source of truth — both [NsdAdvertiser]
 * and [NsdDiscovery] reference these constants.
 */
object PeerTxtKeys {
    const val DVAI_VERSION = "dvaiVersion"
    const val DEVICE_ID = "deviceId"
    const val DEVICE_NAME = "deviceName"
    const val MODELS = "models"
    const val CAPABILITY = "capability"
    const val SECURE = "secure"
}

/**
 * Parse a TXT-record map into a [Peer]. Returns null when required
 * fields are missing (deviceId, dvaiVersion). Used by [NsdDiscovery]
 * after `NsdManager.resolveService` resolves the host + port.
 */
fun parsePeerTxt(
    txt: Map<String, String>,
    baseUrl: String,
    via: PeerSource = PeerSource.MDNS,
    lastSeenAt: Long = System.currentTimeMillis(),
): Peer? {
    val deviceId = txt[PeerTxtKeys.DEVICE_ID]?.takeIf { it.isNotEmpty() } ?: return null
    val dvaiVersion = txt[PeerTxtKeys.DVAI_VERSION]?.takeIf { it.isNotEmpty() } ?: return null
    val deviceName = txt[PeerTxtKeys.DEVICE_NAME] ?: deviceId
    val models = txt[PeerTxtKeys.MODELS]
        ?.split(",")
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() }
        ?: emptyList()
    val capability = txt[PeerTxtKeys.CAPABILITY]
        ?.split(",")
        ?.mapNotNull { entry ->
            val pivot = entry.indexOf(':')
            if (pivot <= 0) return@mapNotNull null
            val key = entry.substring(0, pivot).trim()
            val value = entry.substring(pivot + 1).trim().toDoubleOrNull() ?: return@mapNotNull null
            key to value
        }
        ?.toMap()
        ?: emptyMap()
    val secure = txt[PeerTxtKeys.SECURE]?.equals("true", ignoreCase = true) == true
    return Peer(
        deviceId = deviceId,
        deviceName = deviceName,
        dvaiVersion = dvaiVersion,
        baseUrl = baseUrl,
        loadedModels = models,
        capability = capability,
        via = via,
        secure = secure,
        lastSeenAt = lastSeenAt,
    )
}

/**
 * Serialize a peer to a TXT-record map ready for `NsdServiceInfo`.
 * Inverse of [parsePeerTxt]. Caller is responsible for setting the
 * port on the `NsdServiceInfo` separately.
 */
fun Peer.toTxt(): Map<String, String> = buildMap {
    put(PeerTxtKeys.DEVICE_ID, deviceId)
    put(PeerTxtKeys.DEVICE_NAME, deviceName)
    put(PeerTxtKeys.DVAI_VERSION, dvaiVersion)
    if (loadedModels.isNotEmpty()) put(PeerTxtKeys.MODELS, loadedModels.joinToString(","))
    if (capability.isNotEmpty()) {
        put(PeerTxtKeys.CAPABILITY, capability.entries.joinToString(",") { "${it.key}:${it.value}" })
    }
    if (secure) put(PeerTxtKeys.SECURE, "true")
}
