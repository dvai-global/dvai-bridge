package co.deepvoiceai.bridge.rn

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap

/**
 * Old Architecture (legacy bridge) variant of the DVAIBridge React Native
 * module. Used when `newArchEnabled=false` (Bridgeless OFF). Picked up by
 * the source-set switch in `android/build.gradle`.
 *
 * RN ≥ 0.77 ships with Bridgeless ON by default, so this class exists
 * mainly as a safety net for downstream consumers temporarily forced onto
 * the legacy bridge while migrating. All real logic lives in
 * [DVAIBridgeNativeModuleImpl].
 */
class DVAIBridgeNativeModule(
    reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext) {

    private val impl = DVAIBridgeNativeModuleImpl(reactContext)

    override fun getName(): String = NAME

    @ReactMethod
    fun startBridge(opts: ReadableMap, promise: Promise) {
        impl.startBridge(opts, promise)
    }

    @ReactMethod
    fun stopBridge(promise: Promise) {
        impl.stopBridge(promise)
    }

    @ReactMethod
    fun status(promise: Promise) {
        impl.status(promise)
    }

    @ReactMethod
    fun downloadModel(opts: ReadableMap, promise: Promise) {
        impl.downloadModel(opts, promise)
    }

    @ReactMethod
    fun assessHardware(hardwareMinimum: Double, minLocalCapability: Double, promise: Promise) {
        impl.assessHardware(hardwareMinimum, minLocalCapability, promise)
    }

    @ReactMethod
    fun addListener(eventName: String) {
        impl.addListener(eventName)
    }

    @ReactMethod
    fun removeListeners(count: Double) {
        impl.removeListeners(count.toInt())
    }

    override fun invalidate() {
        impl.invalidate()
        super.invalidate()
    }

    companion object {
        const val NAME = "DVAIBridge"
    }
}
