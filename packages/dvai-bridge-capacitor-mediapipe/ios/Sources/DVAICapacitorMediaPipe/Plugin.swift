import Foundation

#if canImport(Capacitor)
import Capacitor

/// Stub iOS plugin — MediaPipe LLM is Android-only.
///
/// Apps that bundle `@dvai-bridge/capacitor-mediapipe` on iOS link this
/// rejection-only surface so the build succeeds, but every method
/// returns the Android-only message. Task 47 fills out the surface with
/// any remaining methods (status currently resolves with `running:false`,
/// `backend:"mediapipe"`, the rest reject).
@objc(DVAIBridgeMediaPipePlugin)
public class DVAIBridgeMediaPipePlugin: CAPPlugin {
    @objc func start(_ call: CAPPluginCall) { rejectAndroidOnly(call) }
    @objc func stop(_ call: CAPPluginCall) { rejectAndroidOnly(call) }

    @objc func status(_ call: CAPPluginCall) {
        call.resolve(["running": false, "backend": "mediapipe"])
    }

    @objc func downloadModel(_ call: CAPPluginCall) { rejectAndroidOnly(call) }
    @objc func listCachedModels(_ call: CAPPluginCall) { rejectAndroidOnly(call) }
    @objc func deleteCachedModel(_ call: CAPPluginCall) { rejectAndroidOnly(call) }
    @objc func cacheDir(_ call: CAPPluginCall) { rejectAndroidOnly(call) }

    private func rejectAndroidOnly(_ call: CAPPluginCall) {
        call.reject("MediaPipe LLM is Android-only. Use a different backend on iOS.")
    }
}
#endif
