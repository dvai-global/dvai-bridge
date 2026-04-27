package co.deepvoiceai.bridge.rn

import com.facebook.react.TurboReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

/**
 * `ReactPackage` registration for the DVAIBridge TurboModule. Picked up by
 * RN's autolinking via `react-native.config.js` — the consumer's
 * `MainApplication` doesn't need to add anything manually.
 *
 * `TurboReactPackage` (rather than the legacy `ReactPackage`) lets the
 * package satisfy both old-arch and new-arch (TurboModule) registration
 * paths from a single class.
 */
class DVAIBridgePackage : TurboReactPackage() {

    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? {
        return if (name == DVAIBridgeNativeModule.NAME) {
            DVAIBridgeNativeModule(reactContext)
        } else {
            null
        }
    }

    override fun getReactModuleInfoProvider(): ReactModuleInfoProvider {
        return ReactModuleInfoProvider {
            mapOf(
                DVAIBridgeNativeModule.NAME to ReactModuleInfo(
                    DVAIBridgeNativeModule.NAME,
                    DVAIBridgeNativeModule::class.java.name,
                    /* canOverrideExistingModule = */ false,
                    /* needsEagerInit = */ false,
                    /* isCxxModule = */ false,
                    /* isTurboModule = */ BuildConfig.IS_NEW_ARCHITECTURE_ENABLED,
                ),
            )
        }
    }
}
