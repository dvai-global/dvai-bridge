package co.deepvoiceai.dvaibridge.llama

import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin

@CapacitorPlugin(name = "DVAIBridgeLlama")
class DVAIBridgeLlamaPlugin : Plugin() {

    @PluginMethod
    fun start(call: PluginCall) {
        call.reject("Not implemented yet -- Task 28")
    }

    @PluginMethod
    fun stop(call: PluginCall) {
        call.reject("Not implemented yet -- Task 28")
    }

    @PluginMethod
    fun status(call: PluginCall) {
        val ret = JSObject()
        ret.put("running", false)
        call.resolve(ret)
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
