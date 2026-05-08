package co.deepvoiceai.bridge.rn

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap

/**
 * New Architecture (TurboModule) variant. Subclasses the codegen-generated
 * `NativeDVAIBridgeSpec` (emitted at Gradle sync from
 * `src/NativeDVAIBridge.ts` via the `codegenConfig` block in `package.json`).
 *
 * All actual logic lives in [DVAIBridgeNativeModuleImpl] — this class is a
 * thin forwarder so the impl is shared with the old-arch variant under
 * `src/oldarch/`.
 */
class DVAIBridgeNativeModule(
    reactContext: ReactApplicationContext,
) : NativeDVAIBridgeSpec(reactContext) {

    private val impl = DVAIBridgeNativeModuleImpl(reactContext)

    override fun getName(): String = NAME

    override fun startBridge(opts: ReadableMap, promise: Promise) {
        impl.startBridge(opts, promise)
    }

    override fun stopBridge(promise: Promise) {
        impl.stopBridge(promise)
    }

    override fun status(promise: Promise) {
        impl.status(promise)
    }

    override fun downloadModel(opts: ReadableMap, promise: Promise) {
        impl.downloadModel(opts, promise)
    }

    override fun assessHardware(
        hardwareMinimum: Double,
        minLocalCapability: Double,
        promise: Promise,
    ) {
        impl.assessHardware(hardwareMinimum, minLocalCapability, promise)
    }

    override fun addListener(eventName: String) {
        impl.addListener(eventName)
    }

    override fun removeListeners(count: Double) {
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
