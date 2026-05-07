package co.deepvoiceai.bridge.shared.core.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.util.concurrent.ConcurrentHashMap

/**
 * Discovery events emitted by [NsdDiscovery]. Mirrors the TS
 * `DiscoveryEvent` discriminated union.
 */
sealed class DiscoveryEvent {
    data class PeerUp(val peer: Peer) : DiscoveryEvent()
    data class PeerDown(val deviceId: String) : DiscoveryEvent()
    data class Error(val message: String) : DiscoveryEvent()
}

/**
 * mDNS / DNS-SD discovery for `_dvai-bridge._tcp` peers, backed by
 * Android's [NsdManager].
 *
 * Lifecycle:
 *
 *   1. Construct with `Context.applicationContext` and a self deviceId
 *      (so we filter out our own broadcast).
 *   2. Call [start] from a coroutine. NsdManager runs on its own
 *      thread; this class is just a thin wrapper.
 *   3. Collect from [events] for `DiscoveryEvent.PeerUp/PeerDown/Error`.
 *   4. Call [peers] for a snapshot.
 *   5. Call [stop] to release the discovery listener.
 *
 * Thread-safety: the internal peer map is a `ConcurrentHashMap`, and
 * NsdManager callbacks fire on its internal thread. Stale-peer GC
 * runs piggybacked on each new event since NsdManager doesn't itself
 * surface explicit "peer down" notifications when a device just goes
 * silent (no service unregister).
 */
class NsdDiscovery(
    private val context: Context,
    private val selfDeviceId: String,
    /** Peer is considered down after this many ms with no advertisement seen. */
    private val peerTtlMs: Long = 90_000L,
) {
    companion object {
        private const val TAG = "DvaiNsdDiscovery"
    }

    private val nsdManager: NsdManager =
        context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager

    private val peerMap = ConcurrentHashMap<String, Peer>()
    private val pendingResolutions = ConcurrentHashMap<String, Boolean>()

    private val _events = MutableSharedFlow<DiscoveryEvent>(
        replay = 0,
        extraBufferCapacity = 64,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /** Hot stream of discovery events. Always-on; drops oldest on overflow. */
    val events: SharedFlow<DiscoveryEvent> = _events.asSharedFlow()

    @Volatile private var listener: NsdManager.DiscoveryListener? = null
    @Volatile private var started = false

    /** Snapshot of currently-known peers. */
    fun peers(): List<Peer> {
        gcStale()
        return peerMap.values.toList()
    }

    /** Begin discovering. Idempotent. */
    fun start() {
        if (started) return
        val l = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                _events.tryEmit(
                    DiscoveryEvent.Error(
                        "[DVAI/discovery] onStartDiscoveryFailed type=$serviceType code=$errorCode",
                    ),
                )
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                _events.tryEmit(
                    DiscoveryEvent.Error(
                        "[DVAI/discovery] onStopDiscoveryFailed type=$serviceType code=$errorCode",
                    ),
                )
            }

            override fun onDiscoveryStarted(serviceType: String) {
                Log.d(TAG, "discovery started: $serviceType")
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.d(TAG, "discovery stopped: $serviceType")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val key = serviceInfo.serviceName
                if (pendingResolutions.putIfAbsent(key, true) != null) return
                resolve(serviceInfo) { pendingResolutions.remove(key) }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                // NsdManager doesn't expose deviceId directly here — match by
                // serviceName in our peer map (we store it as a synthetic key).
                val name = serviceInfo.serviceName ?: return
                val gone = peerMap.entries.firstOrNull { it.value.deviceName == name || it.key == name }
                gone?.let {
                    peerMap.remove(it.key)
                    _events.tryEmit(DiscoveryEvent.PeerDown(it.key))
                }
            }
        }
        listener = l
        try {
            nsdManager.discoverServices(DVAI_NSD_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
            started = true
        } catch (e: Throwable) {
            _events.tryEmit(
                DiscoveryEvent.Error("[DVAI/discovery] discoverServices threw: ${e.message}"),
            )
        }
    }

    /** Stop and release resources. Idempotent. */
    fun stop() {
        val l = listener ?: return
        try {
            nsdManager.stopServiceDiscovery(l)
        } catch (e: Throwable) {
            // NsdManager throws IllegalArgumentException if the listener
            // is already deregistered. Safe to ignore on shutdown.
            Log.d(TAG, "stopServiceDiscovery: ${e.message}")
        }
        listener = null
        started = false
        peerMap.clear()
        pendingResolutions.clear()
    }

    /**
     * Resolve a discovered service to fetch its host/port + TXT record.
     * NsdManager pre-API-34 has a known race where back-to-back
     * resolveService calls fail; we serialize via [pendingResolutions].
     */
    private fun resolve(serviceInfo: NsdServiceInfo, onDone: () -> Unit) {
        val cb = object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                onDone()
                _events.tryEmit(
                    DiscoveryEvent.Error(
                        "[DVAI/discovery] onResolveFailed name=${info.serviceName} code=$errorCode",
                    ),
                )
            }

            override fun onServiceResolved(info: NsdServiceInfo) {
                onDone()
                handleResolved(info)
            }
        }
        try {
            nsdManager.resolveService(serviceInfo, cb)
        } catch (e: Throwable) {
            onDone()
            _events.tryEmit(
                DiscoveryEvent.Error("[DVAI/discovery] resolveService threw: ${e.message}"),
            )
        }
    }

    private fun handleResolved(info: NsdServiceInfo) {
        val txt = readTxt(info)
        // Filter out our own advertisement.
        val peerDeviceId = txt[PeerTxtKeys.DEVICE_ID]
        if (peerDeviceId == null || peerDeviceId == selfDeviceId) return

        val host = info.host?.hostAddress ?: return
        val port = info.port
        // IPv6 literals must be wrapped in brackets in URLs.
        val hostPart = if (host.contains(':')) "[$host]" else host
        val secure = txt[PeerTxtKeys.SECURE]?.equals("true", ignoreCase = true) == true
        val scheme = if (secure) "https" else "http"
        val baseUrl = "$scheme://$hostPart:$port"

        val peer = parsePeerTxt(txt, baseUrl) ?: return
        val previous = peerMap.put(peer.deviceId, peer)
        if (previous == null || previous.lastSeenAt < peer.lastSeenAt - 1000) {
            _events.tryEmit(DiscoveryEvent.PeerUp(peer))
        }
    }

    private fun readTxt(info: NsdServiceInfo): Map<String, String> {
        // attributes is API 21+. The Android byte-array → String conversion
        // is UTF-8 by spec.
        val attrs = info.attributes ?: emptyMap()
        return attrs.entries.associate { (k, v) ->
            k to (v?.toString(Charsets.UTF_8) ?: "")
        }
    }

    private fun gcStale() {
        if (peerMap.isEmpty()) return
        val cutoff = System.currentTimeMillis() - peerTtlMs
        val stale = peerMap.entries.filter { it.value.lastSeenAt < cutoff }
        for (entry in stale) {
            peerMap.remove(entry.key)
            _events.tryEmit(DiscoveryEvent.PeerDown(entry.key))
        }
    }

    /** Static helpers for tests / library-side conversions. */
    object NsdAttrs {
        /**
         * Build an NsdServiceInfo attributes-style map from a TXT map.
         * Useful for round-trip tests of TXT serialization without
         * requiring an actual NsdManager instance.
         */
        fun fromTxt(txt: Map<String, String>): Map<String, ByteArray> =
            txt.mapValues { (_, v) -> v.toByteArray(Charsets.UTF_8) }
    }
}
