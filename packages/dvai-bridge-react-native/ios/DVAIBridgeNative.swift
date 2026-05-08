// DVAIBridgeNative.swift
//
// Swift implementation of the React Native TurboModule bridge for the
// `@dvai-bridge/react-native` package.
//
// Responsibilities:
//
//  1. Translate JS-side TurboModule calls (`startBridge` / `stopBridge` /
//     `status` / `downloadModel`) into calls against `DVAIBridge.shared`
//     (the Phase 3C umbrella actor).
//  2. Convert `NSDictionary` opts ↔ Swift structs and vice versa for the
//     return values.
//  3. Bridge thrown `DVAIBridgeError` values to RN's promise-rejection
//     shape, preserving the stable `kind` discriminator.
//  4. Subscribe to `DVAIBridge.shared.progressPublisher` (Combine) and
//     forward every event to the JS side as a `DVAIBridgeProgress`
//     RCTEventEmitter event with the canonical JSON shape.
//
// The module name exposed to JS is `"DVAIBridge"` (see `RCT_EXTERN_REMAP_MODULE`
// in DVAIBridgeNative.mm).

import Foundation
import Combine
import DVAIBridge
import React

@objc(DVAIBridgeNative)
@objcMembers
final class DVAIBridgeNative: RCTEventEmitter {
    // MARK: - Setup

    /// Set true once at least one JS-side listener is attached. We avoid
    /// emitting events into a void when nobody's listening (RN logs a
    /// warning otherwise).
    private var hasListeners: Bool = false

    /// Combine subscription tracking the bridge's progress publisher.
    /// Lazily attached on the first listener and torn down when listener
    /// count drops to zero.
    private var progressCancellable: AnyCancellable?

    override init() {
        super.init()
    }

    deinit {
        progressCancellable?.cancel()
    }

    // MARK: - RCTEventEmitter overrides

    override static func requiresMainQueueSetup() -> Bool {
        return false
    }

    override func supportedEvents() -> [String]! {
        return ["DVAIBridgeProgress"]
    }

    override func startObserving() {
        hasListeners = true
        attachProgressSubscription()
    }

    override func stopObserving() {
        hasListeners = false
        progressCancellable?.cancel()
        progressCancellable = nil
    }

    private func attachProgressSubscription() {
        // Tear down any prior subscription before re-attaching.
        progressCancellable?.cancel()
        let publisher: AnyPublisher<ProgressEvent, Never> = DVAIBridge.shared.progressPublisher
        progressCancellable = publisher.sink { [weak self] event in
            guard let self = self, self.hasListeners else { return }
            self.sendEvent(withName: "DVAIBridgeProgress", body: Self.toJSEvent(event))
        }
    }

    // MARK: - Lifecycle methods (callable from JS)

    @objc
    func startBridge(_ opts: NSDictionary,
                     resolver resolve: @escaping RCTPromiseResolveBlock,
                     rejecter reject: @escaping RCTPromiseRejectBlock) {
        let config: DVAIBridgeConfig
        do {
            config = try Self.parseStartOptions(opts)
        } catch let err as DVAIBridgeError {
            Self.rejectWith(err, reject: reject)
            return
        } catch {
            reject("configurationInvalid", error.localizedDescription, error)
            return
        }

        Task {
            do {
                let server = try await DVAIBridge.shared.start(config)
                resolve(Self.toBoundServerDict(server))
            } catch let err as DVAIBridgeError {
                Self.rejectWith(err, reject: reject)
            } catch {
                reject("backendError", error.localizedDescription, error)
            }
        }
    }

    @objc
    func stopBridge(_ resolve: @escaping RCTPromiseResolveBlock,
                    rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task {
            do {
                try await DVAIBridge.shared.stop()
                resolve(NSNull())
            } catch let err as DVAIBridgeError {
                Self.rejectWith(err, reject: reject)
            } catch {
                reject("backendError", error.localizedDescription, error)
            }
        }
    }

    @objc
    func status(_ resolve: @escaping RCTPromiseResolveBlock,
                rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task {
            let info = await DVAIBridge.shared.status()
            var dict: [String: Any] = ["running": info.running]
            if let baseUrl = info.baseUrl { dict["baseUrl"] = baseUrl }
            if let backend = info.backend { dict["backend"] = backend.rawValue }
            // Port is parseable from baseUrl but the JS side prefers it as a
            // first-class field. Pull it out when available.
            if let baseUrl = info.baseUrl,
               let url = URL(string: baseUrl),
               let port = url.port {
                dict["port"] = port
            }
            resolve(dict)
        }
    }

    @objc
    func assessHardware(_ hardwareMinimum: NSNumber,
                        minLocalCapability: NSNumber,
                        resolver resolve: @escaping RCTPromiseResolveBlock,
                        rejecter reject: @escaping RCTPromiseRejectBlock) {
        let a = DVAIBridge.shared.assessHardware(
            hardwareMinimum: hardwareMinimum.doubleValue,
            minLocalCapability: minLocalCapability.doubleValue
        )
        let hintsDict: [String: Any] = [
            "hasNpu": a.hints.hasNpu,
            "ramGb": a.hints.ramGb,
            "gpuClass": a.hints.gpuClass.rawValue,
            "cpuClass": a.hints.cpuClass.rawValue,
        ]
        let dict: [String: Any] = [
            "mode": a.mode.rawValue,
            "tokPerSec": a.tokPerSec,
            "reason": a.reason,
            "hints": hintsDict,
        ]
        resolve(dict)
    }

    @objc
    func downloadModel(_ opts: NSDictionary,
                       resolver resolve: @escaping RCTPromiseResolveBlock,
                       rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let urlString = opts["url"] as? String,
              let url = URL(string: urlString) else {
            reject("configurationInvalid", "downloadModel: missing or invalid `url`", nil)
            return
        }
        guard let sha256 = opts["sha256"] as? String, !sha256.isEmpty else {
            reject("configurationInvalid", "downloadModel: missing `sha256`", nil)
            return
        }
        let destFilename = opts["destFilename"] as? String
        let headers = (opts["headers"] as? [String: String]) ?? [:]

        let downloadOpts = DVAIBridge.DownloadOptions(
            url: url,
            sha256: sha256,
            destFilename: destFilename,
            headers: headers
        )

        Task {
            do {
                let result = try await DVAIBridge.shared.downloadModel(downloadOpts)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: result.path)[.size] as? NSNumber)?.int64Value ?? 0
                let dict: [String: Any] = [
                    "path": result.path,
                    "sha256": sha256.lowercased(),
                    "sizeBytes": fileSize,
                    "cached": result.cached,
                ]
                resolve(dict)
            } catch let err as DVAIBridgeError {
                Self.rejectWith(err, reject: reject)
            } catch {
                reject("downloadFailed", error.localizedDescription, error)
            }
        }
    }

    // MARK: - Conversions

    /// Translate the JS-side `StartOptions` (NSDictionary) into a
    /// `DVAIBridgeConfig`. Throws `configurationInvalid` for malformed
    /// `backend` / `corsOrigin` shapes; throws `backendUnavailable` if the
    /// JS side somehow bypasses the TS-level platform validation.
    private static func parseStartOptions(_ opts: NSDictionary) throws -> DVAIBridgeConfig {
        guard let backendStr = opts["backend"] as? String else {
            throw DVAIBridgeError.configurationInvalid(reason: "missing `backend`")
        }
        guard let backend = BackendKind(rawValue: backendStr) else {
            // Android-only backends ("mediapipe", "litert") fall here on iOS —
            // surface as backendUnavailable for parity with the TS-side
            // pre-validation.
            throw DVAIBridgeError.backendUnavailable(.auto, reason: "Backend \"\(backendStr)\" is not available on iOS.")
        }
        var config = DVAIBridgeConfig(backend: backend)

        if let modelPath = opts["modelPath"] as? String { config.modelPath = modelPath }
        if let mmprojPath = opts["mmprojPath"] as? String { config.mmprojPath = mmprojPath }
        if let tokenizerPath = opts["tokenizerPath"] as? String { config.tokenizerPath = tokenizerPath }
        if let gpuLayers = opts["gpuLayers"] as? NSNumber { config.gpuLayers = gpuLayers.intValue }
        if let contextSize = opts["contextSize"] as? NSNumber { config.contextSize = contextSize.intValue }
        if let threads = opts["threads"] as? NSNumber { config.threads = threads.intValue }
        if let embeddingMode = opts["embeddingMode"] as? Bool { config.embeddingMode = embeddingMode }
        if let httpBasePort = opts["httpBasePort"] as? NSNumber { config.httpBasePort = httpBasePort.intValue }
        if let httpMaxPortAttempts = opts["httpMaxPortAttempts"] as? NSNumber {
            config.httpMaxPortAttempts = httpMaxPortAttempts.intValue
        }
        if let autoUnload = opts["autoUnloadOnLowMemory"] as? Bool {
            config.autoUnloadOnLowMemory = autoUnload
        }
        if let logLevel = opts["logLevel"] as? String { config.logLevel = logLevel }

        if let corsRaw = opts["corsOrigin"] {
            if let s = corsRaw as? String {
                config.corsOrigin = (s == "*") ? .wildcard : .exact(s)
            } else if let xs = corsRaw as? [String] {
                config.corsOrigin = .allowlist(xs)
            }
        }

        return config
    }

    /// Convert a `BoundServer` to the `[String: Any]` shape the JS side
    /// expects.
    private static func toBoundServerDict(_ server: BoundServer) -> [String: Any] {
        return [
            "baseUrl": server.baseUrl,
            "port": server.port,
            "backend": server.backend.rawValue,
            "modelId": server.modelId,
        ]
    }

    /// Convert a `ProgressEvent` to the canonical JS event shape:
    /// `{ kind, phase, percent?, message?, error? }`.
    ///
    /// The iOS `ProgressEvent` model uses a `Phase` enum (`download` /
    /// `verify` / `load` / `ready` / `error`) that the JS side doesn't
    /// distinguish. Map them to the `kind` + `phase` discriminator pair
    /// expected on the JS side:
    ///
    ///  - `.download`            -> kind `progress`, phase `download`
    ///  - `.verify`              -> kind `progress`, phase `download`
    ///  - `.load`                -> kind `progress`, phase `start`
    ///  - `.ready`               -> kind `completed`, phase `start`
    ///  - `.error`               -> kind `failed`, phase `start`
    ///                              (the underlying error message is
    ///                              forwarded under `error.message`)
    private static func toJSEvent(_ event: ProgressEvent) -> [String: Any] {
        var dict: [String: Any] = [:]

        switch event.phase {
        case .download:
            dict["kind"] = "progress"
            dict["phase"] = "download"
        case .verify:
            dict["kind"] = "progress"
            dict["phase"] = "download"
            dict["message"] = "verifying"
        case .load:
            dict["kind"] = "progress"
            dict["phase"] = "start"
        case .ready:
            dict["kind"] = "completed"
            dict["phase"] = "start"
        case .error:
            dict["kind"] = "failed"
            dict["phase"] = "start"
            dict["error"] = [
                "kind": "backendError",
                "message": event.message ?? "unknown error",
            ]
        }

        if let percent = event.percent {
            dict["percent"] = percent
        }
        if let message = event.message, dict["message"] == nil {
            dict["message"] = message
        }
        return dict
    }

    /// Reject an RN promise with a `DVAIBridgeError`. The `code` is the
    /// stable `DVAIBridgeErrorKind` discriminator; the JS side's
    /// `DVAIBridgeError.fromNative` uses it to reconstruct the typed error.
    private static func rejectWith(_ err: DVAIBridgeError, reject: RCTPromiseRejectBlock) {
        let code: String
        var userInfo: [String: Any] = [:]
        switch err {
        case .notStarted:
            code = "notStarted"
        case .alreadyStarted(let backend, let baseUrl):
            code = "alreadyStarted"
            userInfo["currentBackend"] = backend.rawValue
            userInfo["baseUrl"] = baseUrl
        case .configurationInvalid:
            code = "configurationInvalid"
        case .backendUnavailable(let backend, _):
            code = "backendUnavailable"
            userInfo["backend"] = backend.rawValue
        case .modelLoadFailed:
            code = "modelLoadFailed"
        case .downloadFailed:
            code = "downloadFailed"
        case .checksumMismatch:
            code = "checksumMismatch"
        case .backendError:
            code = "backendError"
        }
        userInfo["kind"] = code
        let nsError = NSError(
            domain: "co.deepvoiceai.bridge",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: err.errorDescription ?? "Unknown bridge error"]
                .merging(userInfo) { _, new in new }
        )
        reject(code, err.errorDescription ?? "Unknown bridge error", nsError)
    }
}
