import Foundation

#if canImport(Capacitor)
import Capacitor

@objc(DVAIBridgeLlamaPlugin)
public class DVAIBridgeLlamaPlugin: CAPPlugin {
    private let state = PluginState()

    public override func load() {
        super.load()
    }

    @objc func start(_ call: CAPPluginCall) {
        let opts = call.options ?? [:]
        Task {
            do {
                let result = try await state.start(opts: opts)
                call.resolve(result)
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        Task {
            do {
                try await state.stop()
                call.resolve()
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func status(_ call: CAPPluginCall) {
        Task {
            let info = await state.statusInfo()
            call.resolve(info)
        }
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
