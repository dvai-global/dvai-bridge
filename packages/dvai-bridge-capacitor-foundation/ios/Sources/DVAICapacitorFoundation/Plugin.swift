import Foundation

#if canImport(Capacitor)
import Capacitor

@objc(DVAIBridgeFoundationPlugin)
public class DVAIBridgeFoundationPlugin: CAPPlugin {
    private let state = PluginState()

    public override func load() {
        super.load()
    }

    // MARK: - Lifecycle

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
