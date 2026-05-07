package co.deepvoiceai.bridge.shared.core.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log

/**
 * Advertises THIS device on the LAN as a `_dvai-bridge._tcp` mDNS
 * service via Android's [NsdManager.registerService]. Pairs with
 * [NsdDiscovery] running on peers.
 *
 * The TXT record exposes: deviceId, deviceName, dvaiVersion, models,
 * capability — see [PeerTxtKeys].
 */
class NsdAdvertiser(
    private val context: Context,
) {
    companion object {
        private const val TAG = "DvaiNsdAdvertiser"
    }

    private val nsdManager: NsdManager =
        context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager

    @Volatile private var listener: NsdManager.RegistrationListener? = null
    @Volatile private var started = false

    /**
     * Begin advertising. Idempotent — a second [start] with the same
     * config is a no-op.
     */
    fun start(
        serviceName: String,
        port: Int,
        txt: Map<String, String>,
    ) {
        if (started) return
        val info = NsdServiceInfo().apply {
            this.serviceName = serviceName
            this.serviceType = DVAI_NSD_SERVICE_TYPE
            this.port = port
            for ((k, v) in txt) {
                setAttribute(k, v)
            }
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "registration failed code=$errorCode")
                started = false
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "unregistration failed code=$errorCode")
            }

            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.d(TAG, "registered: ${info.serviceName}")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.d(TAG, "unregistered: ${info.serviceName}")
            }
        }
        listener = l
        try {
            nsdManager.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
            started = true
        } catch (e: Throwable) {
            Log.w(TAG, "registerService threw: ${e.message}")
            listener = null
        }
    }

    /** Unregister. Idempotent. */
    fun stop() {
        val l = listener ?: return
        try {
            nsdManager.unregisterService(l)
        } catch (e: Throwable) {
            Log.d(TAG, "unregisterService: ${e.message}")
        }
        listener = null
        started = false
    }
}
