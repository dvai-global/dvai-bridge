package co.deepvoiceai.bridge.llama

import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import co.deepvoiceai.bridge.llama.core.ModelDownloader
import co.deepvoiceai.bridge.llama.core.PluginState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

// ---------------------------------------------------------------------------
// JSObject ↔ Map translation helpers — needed because PluginState's API is
// Capacitor-neutral (Map<String, Any?>) while the JS-bridge layer works with
// Capacitor's JSObject (which extends JSONObject and has no .toMap()).
// ---------------------------------------------------------------------------

private fun JSObject.toAnyMap(): Map<String, Any?> {
    val out = mutableMapOf<String, Any?>()
    val it = keys()
    while (it.hasNext()) {
        val k = it.next()
        out[k] = this.opt(k)  // returns Any (or JSONObject.NULL); fine for our usage
    }
    return out
}

private fun Map<String, Any?>.toJSObject(): JSObject {
    val obj = JSObject()
    for ((k, v) in this) {
        if (v != null) obj.put(k, v)
    }
    return obj
}

@CapacitorPlugin(name = "DVAIBridgeLlama")
class DVAIBridgeLlamaPlugin : Plugin() {
    private val state = PluginState()
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val downloader: ModelDownloader by lazy { ModelDownloader(context) }

    override fun handleOnDestroy() {
        super.handleOnDestroy()
        scope.cancel()
    }

    @PluginMethod
    fun start(call: PluginCall) {
        scope.launch {
            notifyListeners("progress", JSObject().apply { put("phase", "load") })
            try {
                val resultMap = state.start((call.data ?: JSObject()).toAnyMap())
                notifyListeners("progress", JSObject().apply { put("phase", "ready") })
                call.resolve(resultMap.toJSObject())
            } catch (e: Exception) {
                notifyListeners("progress", JSObject().apply {
                    put("phase", "error")
                    put("message", e.message ?: "Start failed")
                })
                call.reject(e.message ?: "Start failed", e)
            }
        }
    }

    @PluginMethod
    fun stop(call: PluginCall) {
        scope.launch {
            try {
                state.stop()
                call.resolve()
            } catch (e: Exception) {
                call.reject(e.message ?: "Stop failed", e)
            }
        }
    }

    @PluginMethod
    fun status(call: PluginCall) {
        scope.launch {
            call.resolve(state.statusInfo().toJSObject())
        }
    }

    @PluginMethod
    fun downloadModel(call: PluginCall) {
        val url = call.getString("url") ?: return call.reject("url is required")
        val sha = call.getString("sha256")?.takeIf { it.isNotEmpty() }?.lowercase()
            ?: return call.reject("sha256 is required")
        val destFilename = call.getString("destFilename") ?: url.substringAfterLast('/')
        val headers: Map<String, String> = call.getObject("headers")?.let { obj ->
            val map = mutableMapOf<String, String>()
            obj.keys().forEachRemaining { k -> obj.getString(k)?.let { map[k] = it } }
            map
        } ?: emptyMap()

        scope.launch {
            try {
                val (path, cached) = downloader.downloadModel(
                    url = url,
                    expectedSha256 = sha,
                    destFilename = destFilename,
                    headers = headers,
                ) { bytesDone, bytesTotal ->
                    val payload = JSObject().apply {
                        put("phase", "download")
                        put("bytesReceived", bytesDone)
                        if (bytesTotal != null) {
                            put("bytesTotal", bytesTotal)
                            if (bytesTotal > 0) {
                                put("percent", bytesDone.toDouble() / bytesTotal.toDouble() * 100.0)
                            }
                        }
                    }
                    notifyListeners("progress", payload)
                }
                call.resolve(JSObject().apply {
                    put("path", path)
                    put("cached", cached)
                })
            } catch (e: Exception) {
                call.reject(e.message ?: "Download failed", e)
            }
        }
    }

    @PluginMethod
    fun listCachedModels(call: PluginCall) {
        scope.launch {
            try {
                val infos = downloader.listCached()
                val arr = JSArray()
                infos.forEach { info ->
                    arr.put(JSObject().apply {
                        put("filename", info.filename)
                        put("path", info.path)
                        put("bytes", info.bytes)
                        put("sha256", info.sha256)
                    })
                }
                call.resolve(JSObject().apply { put("models", arr) })
            } catch (e: Exception) {
                call.reject(e.message ?: "List failed", e)
            }
        }
    }

    @PluginMethod
    fun deleteCachedModel(call: PluginCall) {
        val filename = call.getString("filename")?.takeIf { it.isNotEmpty() }
            ?: return call.reject("filename is required")
        scope.launch {
            try {
                downloader.deleteCached(filename)
                call.resolve()
            } catch (e: Exception) {
                call.reject(e.message ?: "Delete failed", e)
            }
        }
    }

    @PluginMethod
    fun cacheDir(call: PluginCall) {
        scope.launch {
            try {
                val path = downloader.cacheDir().absolutePath
                call.resolve(JSObject().apply { put("path", path) })
            } catch (e: Exception) {
                call.reject(e.message ?: "cacheDir failed", e)
            }
        }
    }
}
