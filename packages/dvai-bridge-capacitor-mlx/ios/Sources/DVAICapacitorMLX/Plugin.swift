import Foundation
import DVAIMLXCore

#if canImport(Capacitor)
import Capacitor

@objc(DVAIBridgeMLXPlugin)
public class DVAIBridgeMLXPlugin: CAPPlugin {
    private let state = MLXPluginState()

    public override func load() {
        super.load()
    }

    // MARK: - Lifecycle

    @objc func start(_ call: CAPPluginCall) {
        let opts: [String: Any] = (call.options as? [String: Any]) ?? [:]
        Task { [weak self] in
            guard let self else { return }
            self.notifyListeners("progress", data: ["phase": "load"])
            do {
                let result = try await self.state.start(opts: opts)
                self.notifyListeners("progress", data: ["phase": "ready"])
                call.resolve(result)
            } catch {
                self.notifyListeners("progress", data: [
                    "phase": "error",
                    "message": error.localizedDescription,
                ])
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

    // MARK: - Model download / cache
    //
    // mlx-swift-lm uses HuggingFace Hub's local cache (~/Library/Caches/.../
    // huggingface). We don't expose download/list/delete here because:
    //  - Downloads happen implicitly on the first start() with a given
    //    modelPath (the HF id). Subsequent starts are cache-hits.
    //  - Listing / deleting cached MLX models is a HF-Hub-cache operation,
    //    not something the bridge itself controls.
    // Phase 3D may expose pass-through helpers; for now the methods reject
    // by design.

    private static let modelMgmtNotApplicable =
        "MLX backend uses HuggingFace Hub's local cache; explicit download/list/delete is not exposed in this version. Pass an HF model id via the `modelPath` start option and let MLX handle caching."

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
