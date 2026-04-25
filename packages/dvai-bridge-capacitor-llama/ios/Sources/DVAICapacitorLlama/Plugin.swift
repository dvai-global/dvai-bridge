import Foundation

#if canImport(Capacitor)
import Capacitor

@objc(DVAIBridgeLlamaPlugin)
public class DVAIBridgeLlamaPlugin: CAPPlugin {
    public override func load() {
        super.load()
    }

    @objc func start(_ call: CAPPluginCall) {
        call.reject("Not implemented yet — Task 28")
    }

    @objc func stop(_ call: CAPPluginCall) {
        call.reject("Not implemented yet — Task 28")
    }

    @objc func status(_ call: CAPPluginCall) {
        call.resolve(["running": false])
    }

    @objc func downloadModel(_ call: CAPPluginCall) {
        call.reject("Not implemented yet — Task 32")
    }

    @objc func listCachedModels(_ call: CAPPluginCall) {
        call.resolve(["models": []])
    }

    @objc func deleteCachedModel(_ call: CAPPluginCall) {
        call.reject("Not implemented yet — Task 32")
    }

    @objc func cacheDir(_ call: CAPPluginCall) {
        call.reject("Not implemented yet — Task 32")
    }
}
#endif
