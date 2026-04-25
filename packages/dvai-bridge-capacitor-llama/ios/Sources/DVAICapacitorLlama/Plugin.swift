import Foundation

#if canImport(Capacitor)
import Capacitor

@objc(DVAIBridgeLlamaPlugin)
public class DVAIBridgeLlamaPlugin: CAPPlugin {
    private let state = PluginState()
    private let downloader = ModelDownloader()

    public override func load() {
        super.load()
    }

    @objc func start(_ call: CAPPluginCall) {
        let opts = call.options ?? [:]
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

    @objc func downloadModel(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"), let url = URL(string: urlStr) else {
            call.reject("url is required")
            return
        }
        guard let sha = call.getString("sha256"), !sha.isEmpty else {
            call.reject("sha256 is required")
            return
        }
        let destFilename = call.getString("destFilename") ?? url.lastPathComponent
        // Capacitor's JSObject is `[String: Any]`, so an `as? [String: String]`
        // cast returns nil whenever any value isn't already typed as String,
        // silently dropping ALL headers. Mirror Android's per-key extraction.
        var headers: [String: String] = [:]
        if let raw = call.getObject("headers") {
            for (k, v) in raw {
                if let s = v as? String { headers[k] = s }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.downloader.downloadModel(
                    url: url,
                    expectedSha256: sha.lowercased(),
                    destFilename: destFilename,
                    headers: headers,
                    onProgress: { [weak self] bytesDone, bytesTotal in
                        guard let self else { return }
                        var payload: [String: Any] = [
                            "phase": "download",
                            "bytesReceived": bytesDone,
                        ]
                        if let total = bytesTotal {
                            payload["bytesTotal"] = total
                            if total > 0 {
                                payload["percent"] = Double(bytesDone) / Double(total) * 100.0
                            }
                        }
                        self.notifyListeners("progress", data: payload)
                    }
                )
                call.resolve([
                    "path": result.path,
                    "cached": result.cached,
                ])
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func listCachedModels(_ call: CAPPluginCall) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let infos = try await self.downloader.listCachedModels()
                let models: [[String: Any]] = infos.map {
                    [
                        "filename": $0.filename,
                        "path": $0.path,
                        "bytes": $0.bytes,
                        "sha256": $0.sha256,
                    ]
                }
                call.resolve(["models": models])
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func deleteCachedModel(_ call: CAPPluginCall) {
        guard let filename = call.getString("filename"), !filename.isEmpty else {
            call.reject("filename is required")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.downloader.deleteCachedModel(filename: filename)
                call.resolve()
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func cacheDir(_ call: CAPPluginCall) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let path = try await self.downloader.cacheDirPath()
                call.resolve(["path": path])
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }
}
#endif
