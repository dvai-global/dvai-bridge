package co.deepvoiceai.dvaibridge.mediapipe

import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

@CapacitorPlugin(name = "DVAIBridgeMediaPipe")
class DVAIBridgeMediaPipePlugin : Plugin() {
    private val state = PluginState()
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun handleOnDestroy() {
        super.handleOnDestroy()
        scope.cancel()
    }

    @PluginMethod
    fun start(call: PluginCall) {
        scope.launch {
            notifyListeners("progress", JSObject().apply { put("phase", "load") })
            try {
                val result = state.start(call.data, context)
                notifyListeners("progress", JSObject().apply { put("phase", "ready") })
                call.resolve(result)
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
        call.resolve(state.statusInfo())
    }

    // For the MediaPipe backend, model lifecycle is the user's job (we don't
    // ship a downloader in Phase 1). These methods reject. A thin downloader
    // wrapper may land later.

    @PluginMethod
    fun downloadModel(call: PluginCall) {
        call.reject(
            "downloadModel is not implemented for MediaPipe backend in Phase 1. " +
                "Place .task files in the app's filesDir manually."
        )
    }

    @PluginMethod
    fun listCachedModels(call: PluginCall) {
        val ret = JSObject()
        ret.put("models", emptyList<Any>())
        call.resolve(ret)
    }

    @PluginMethod
    fun deleteCachedModel(call: PluginCall) {
        call.reject("deleteCachedModel is not implemented for MediaPipe backend in Phase 1.")
    }

    @PluginMethod
    fun cacheDir(call: PluginCall) {
        call.reject("cacheDir is not implemented for MediaPipe backend in Phase 1.")
    }
}
