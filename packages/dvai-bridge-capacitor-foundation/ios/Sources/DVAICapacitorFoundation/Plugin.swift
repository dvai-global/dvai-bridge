import Foundation

#if canImport(Capacitor)
import Capacitor

@objc(DVAIBridgeFoundationPlugin)
public class DVAIBridgeFoundationPlugin: CAPPlugin {
    public override func load() {
        super.load()
    }

    // MARK: - Lifecycle (Task 41 will wire these to a real PluginState)

    @objc func start(_ call: CAPPluginCall) {
        call.reject("Not implemented yet — Task 41")
    }

    @objc func stop(_ call: CAPPluginCall) {
        call.reject("Not implemented yet — Task 41")
    }

    @objc func status(_ call: CAPPluginCall) {
        call.reject("Not implemented yet — Task 41")
    }

    // MARK: - Model download / cache (not applicable to Apple Foundation Models)
    //
    // Apple manages Foundation Models internally on supported devices.
    // There is nothing for us to download or cache, so these methods
    // reject by design (per the design spec, §10.3).

    private static let modelMgmtNotApplicable =
        "Apple Foundation Models manages models internally — model download/cache is not applicable to this backend."

    @objc func downloadModel(_ call: CAPPluginCall) {
        call.reject(Self.modelMgmtNotApplicable)
    }

    @objc func listCachedModels(_ call: CAPPluginCall) {
        call.reject(Self.modelMgmtNotApplicable)
    }

    @objc func deleteCachedModel(_ call: CAPPluginCall) {
        call.reject(Self.modelMgmtNotApplicable)
    }

    @objc func cacheDir(_ call: CAPPluginCall) {
        call.reject(Self.modelMgmtNotApplicable)
    }
}
#endif
