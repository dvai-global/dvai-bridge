import Foundation
import DVAILiteRTLMCore

#if canImport(Capacitor)
import Capacitor

@objc(DVAIBridgeLiteRTLMPlugin)
public class DVAIBridgeLiteRTLMPlugin: CAPPlugin {
    private let state = LiteRTLMPluginState()

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
    // LiteRT-LM ships as a runtime that consumes a `.litertlm` file the app
    // supplies. Downloading, listing, and deleting model files are the
    // consumer app's responsibility (URLSession + FileManager, or the
    // capacitor-llama plugin's downloadModel if you want a shared
    // implementation). Same posture as capacitor-mlx.

    private static let modelMgmtNotApplicable =
        "LiteRT-LM backend does not manage model files. Download the .litertlm file yourself (URLSession, or the capacitor-llama plugin's downloadModel) and pass its filesystem path via the `modelPath` start option."

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
