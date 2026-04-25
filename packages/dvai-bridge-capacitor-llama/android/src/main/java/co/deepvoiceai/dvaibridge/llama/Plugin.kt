package co.deepvoiceai.dvaibridge.llama

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

@CapacitorPlugin(name = "DVAIBridgeLlama")
class DVAIBridgeLlamaPlugin : Plugin() {
    private val state = PluginState()
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun handleOnDestroy() {
        super.handleOnDestroy()
        scope.cancel()
    }

    @PluginMethod
    fun start(call: PluginCall) {
        scope.launch {
            try {
                val result = state.start(call.data)
                call.resolve(result)
            } catch (e: Exception) {
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

    @PluginMethod
    fun downloadModel(call: PluginCall) {
        call.reject("Not implemented yet -- Task 32")
    }

    @PluginMethod
    fun listCachedModels(call: PluginCall) {
        val ret = JSObject()
        ret.put("models", emptyList<Any>())
        call.resolve(ret)
    }

    @PluginMethod
    fun deleteCachedModel(call: PluginCall) {
        call.reject("Not implemented yet -- Task 32")
    }

    @PluginMethod
    fun cacheDir(call: PluginCall) {
        call.reject("Not implemented yet -- Task 32")
    }
}
