//
//  DVAIBridgeNetBridge.swift
//
//  @objc Swift wrapper around DVAIBridge.shared (Phase 3C umbrella) that
//  re-exports the actor's API as Obj-C-callable completion-handler methods.
//  This is the .NET 10 iOS binding entry point — Microsoft's iOS binding
//  generator (`ApiDefinition.cs` `[BaseType]`) consumes the @objc surface
//  via Sharpie or by hand. We choose the hand-written path (smaller surface,
//  better control over the wire shape).
//
//  Wire format (NSDictionary keys — case-sensitive, lowerCamelCase):
//
//    StartOptions →
//      backend          : NSString  ("auto" | "llama" | "foundation" | "coreml" | "mlx")
//      modelPath        : NSString? (absolute path)
//      tokenizerPath    : NSString?
//      mmprojPath       : NSString?
//      chatTemplate     : NSString?
//      modelId          : NSString?
//      contextSize      : NSNumber (Int32) optional
//      threads          : NSNumber (Int32) optional
//      gpuLayers        : NSNumber (Int32) optional
//      httpBasePort     : NSNumber (Int32) optional
//      httpMaxPortAttempts : NSNumber (Int32) optional
//      corsOrigin       : NSString?  (defaults to "*")
//      temperature      : NSNumber (Double) optional
//      topP             : NSNumber (Double) optional
//      topK             : NSNumber (Int32) optional
//      maxNewTokens     : NSNumber (Int32) optional
//      embeddingMode    : NSNumber (Bool) optional, default false
//      visionEnabled    : NSNumber (Bool) optional, default false
//
//    BoundServer ←
//      baseUrl          : NSString
//      port             : NSNumber (Int32)
//      backend          : NSString  (resolved — never "auto")
//      modelId          : NSString
//
//    StatusInfo ←
//      running          : NSNumber (Bool)
//      baseUrl          : NSString?
//      port             : NSNumber (Int32) ?
//      backend          : NSString?
//      modelId          : NSString?
//
//    DownloadOptions →
//      url              : NSString
//      sha256           : NSString
//      destFilename     : NSString?
//
//    DownloadResult ←
//      path             : NSString
//      sha256           : NSString
//      sizeBytes        : NSNumber (Int64)
//
//    ProgressEvent ←
//      kind             : NSString  ("started" | "progress" | "completed" | "failed")
//      phase            : NSString  ("start" | "stop" | "download" | "load" | "ready" | "verify" | "error")
//      percent          : NSNumber? (Double, 0..100)
//      message          : NSString?
//      errorKind        : NSString?
//      errorMessage     : NSString?
//
//    NSError mapping:
//      domain           = "co.deepvoiceai.bridge"
//      code             = numeric kind index (matches DVAIBridgeErrorKind)
//      userInfo["kind"] = wire string for the kind
//      userInfo["details"] : NSDictionary of kind-specific details
//      userInfo[NSLocalizedDescriptionKey] = human-readable
//

import Foundation
import Combine
import DVAIBridge

@objc(DVAIBridgeNetBridge)
public final class DVAIBridgeNetBridge: NSObject {

    @objc public static let shared = DVAIBridgeNetBridge()

    /// Underlying actor reference. Held weakly via direct call — DVAIBridge.shared
    /// is itself the strong holder.
    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    @objc public func start(
        config: NSDictionary,
        completion: @escaping (NSDictionary?, NSError?) -> Void
    ) {
        Task {
            do {
                let cfg = try Self.parseConfig(config)
                let server = try await DVAIBridge.shared.start(cfg)
                completion(Self.boundServerDict(server), nil)
            } catch let e as DVAIBridgeError {
                completion(nil, Self.toNSError(e))
            } catch {
                let wrapped = DVAIBridgeError.backendError(underlying: error.localizedDescription)
                completion(nil, Self.toNSError(wrapped))
            }
        }
    }

    @objc public func stop(completion: @escaping (NSError?) -> Void) {
        Task {
            do {
                try await DVAIBridge.shared.stop()
                completion(nil)
            } catch let e as DVAIBridgeError {
                completion(Self.toNSError(e))
            } catch {
                completion(Self.toNSError(.backendError(underlying: error.localizedDescription)))
            }
        }
    }

    @objc public func status(completion: @escaping (NSDictionary?, NSError?) -> Void) {
        Task {
            let s = await DVAIBridge.shared.status()
            completion(Self.statusInfoDict(s), nil)
        }
    }

    @objc public func downloadModel(
        options: NSDictionary,
        completion: @escaping (NSDictionary?, NSError?) -> Void
    ) {
        Task {
            do {
                let opts = try Self.parseDownloadOptions(options)
                let result = try await DVAIBridge.shared.downloadModel(opts)
                completion(Self.downloadResultDict(result, sha256: opts.sha256), nil)
            } catch let e as DVAIBridgeError {
                completion(nil, Self.toNSError(e))
            } catch {
                completion(nil, Self.toNSError(.downloadFailed(reason: error.localizedDescription)))
            }
        }
    }

    // MARK: - Progress subscription

    @objc public func subscribeProgress(
        onEvent: @escaping (NSDictionary) -> Void
    ) -> CancellableHandle {
        let cancellable = DVAIBridge.shared.progressPublisher
            .sink { ev in
                onEvent(Self.progressEventDict(ev))
            }
        return CancellableHandle(cancellable: cancellable)
    }

    // MARK: - Marshalling helpers (NSDictionary <-> Swift types)

    private static func parseConfig(_ d: NSDictionary) throws -> DVAIBridgeConfig {
        guard let backendStr = d["backend"] as? String,
              let backend = BackendKind(rawValue: backendStr) else {
            throw DVAIBridgeError.configurationInvalid(reason: "Missing or unknown 'backend' field.")
        }
        // Map .NET StartOptions → Swift DVAIBridgeConfig. The iOS config
        // surface is narrower than the .NET StartOptions superset
        // (no chatTemplate / modelId / temperature / topP / topK /
        // maxNewTokens / visionEnabled — those are Android-only on the
        // native side). Keys not present in the Swift config are silently
        // dropped here; the .NET facade still forwards them in case the
        // SDK adds support later.
        var cfg = DVAIBridgeConfig(backend: backend)
        if let v = d["modelPath"] as? String { cfg.modelPath = v }
        if let v = d["tokenizerPath"] as? String { cfg.tokenizerPath = v }
        if let v = d["mmprojPath"] as? String { cfg.mmprojPath = v }
        if let v = d["contextSize"] as? NSNumber { cfg.contextSize = v.intValue }
        if let v = d["threads"] as? NSNumber { cfg.threads = v.intValue }
        if let v = d["gpuLayers"] as? NSNumber { cfg.gpuLayers = v.intValue }
        if let v = d["httpBasePort"] as? NSNumber { cfg.httpBasePort = v.intValue }
        if let v = d["httpMaxPortAttempts"] as? NSNumber { cfg.httpMaxPortAttempts = v.intValue }
        if let v = d["embeddingMode"] as? NSNumber { cfg.embeddingMode = v.boolValue }
        if let v = d["corsOrigin"] as? String {
            cfg.corsOrigin = v == "*" ? .wildcard : .exact(v)
        }
        return cfg
    }

    private static func boundServerDict(_ s: BoundServer) -> NSDictionary {
        let d = NSMutableDictionary()
        d["baseUrl"] = s.baseUrl
        d["port"] = NSNumber(value: s.port)
        d["backend"] = s.backend.rawValue
        d["modelId"] = s.modelId
        return d
    }

    private static func statusInfoDict(_ s: DVAIBridge.StatusInfo) -> NSDictionary {
        let d = NSMutableDictionary()
        d["running"] = NSNumber(value: s.running)
        if let v = s.baseUrl { d["baseUrl"] = v }
        if let v = s.backend?.rawValue { d["backend"] = v }
        // Port + modelId aren't on the iOS StatusInfo today; fish them from
        // baseUrl when present. The Android SDK's StatusInfo carries them
        // explicitly — we accept the iOS-side asymmetry for now.
        if let url = s.baseUrl, let parsed = URL(string: url), let port = parsed.port {
            d["port"] = NSNumber(value: port)
        }
        return d
    }

    private static func parseDownloadOptions(_ d: NSDictionary) throws -> DVAIBridge.DownloadOptions {
        guard let urlStr = d["url"] as? String, let url = URL(string: urlStr) else {
            throw DVAIBridgeError.configurationInvalid(reason: "Missing or invalid 'url' field.")
        }
        guard let sha = d["sha256"] as? String else {
            throw DVAIBridgeError.configurationInvalid(reason: "Missing 'sha256' field.")
        }
        let dest = d["destFilename"] as? String
        return DVAIBridge.DownloadOptions(url: url, sha256: sha, destFilename: dest)
    }

    private static func downloadResultDict(_ r: DVAIBridge.DownloadResult, sha256: String) -> NSDictionary {
        let d = NSMutableDictionary()
        d["path"] = r.path
        d["sha256"] = sha256
        // sizeBytes isn't on the iOS DownloadResult today; stat the file.
        let size = (try? FileManager.default.attributesOfItem(atPath: r.path)[.size] as? NSNumber)?.int64Value ?? 0
        d["sizeBytes"] = NSNumber(value: size)
        return d
    }

    private static func progressEventDict(_ ev: ProgressEvent) -> NSDictionary {
        let d = NSMutableDictionary()
        // Map ProgressEvent's phase/state into the (kind, phase) pair the
        // .NET facade exposes. The iOS SDK ProgressEvent.Phase only carries
        // 5 cases (download, verify, load, ready, error); we map them to
        // the facade's 7-case ProgressPhase. There's no native "start" /
        // "stop" phase — those map to load/ready and error respectively.
        let phaseStr: String
        switch ev.phase {
        case .download: phaseStr = "download"
        case .load: phaseStr = "load"
        case .ready: phaseStr = "ready"
        case .verify: phaseStr = "verify"
        case .error: phaseStr = "error"
        }
        let kindStr: String
        if ev.phase == .error {
            kindStr = "failed"
        } else if let p = ev.percent, p >= 100.0 {
            kindStr = "completed"
        } else if ev.percent != nil || ev.bytesReceived != nil {
            kindStr = "progress"
        } else if ev.phase == .ready {
            kindStr = "completed"
        } else {
            kindStr = "started"
        }
        d["kind"] = kindStr
        d["phase"] = phaseStr
        if let p = ev.percent { d["percent"] = NSNumber(value: p) }
        if let m = ev.message { d["message"] = m }
        if ev.phase == .error {
            d["errorKind"] = "backend_error"
            if let m = ev.message { d["errorMessage"] = m }
        }
        return d
    }

    // MARK: - Error mapping

    private static func toNSError(_ e: DVAIBridgeError) -> NSError {
        let domain = "co.deepvoiceai.bridge"
        let kindStr: String
        let code: Int
        var details: [String: Any] = [:]
        switch e {
        case .alreadyStarted(let backend, let baseUrl):
            kindStr = "already_started"; code = 0
            details["backend"] = backend.rawValue
            details["baseUrl"] = baseUrl
        case .configurationInvalid(let reason):
            kindStr = "configuration_invalid"; code = 1
            details["reason"] = reason
        case .modelLoadFailed(let reason):
            kindStr = "model_load_failed"; code = 2
            details["reason"] = reason
        case .backendUnavailable(let backend, let reason):
            kindStr = "backend_unavailable"; code = 3
            details["backend"] = backend.rawValue
            details["reason"] = reason
        case .backendError(let underlying):
            kindStr = "backend_error"; code = 4
            details["underlying"] = underlying
        case .checksumMismatch:
            kindStr = "checksum_mismatch"; code = 5
        case .downloadFailed(let reason):
            kindStr = "download_failed"; code = 6
            details["reason"] = reason
        case .notStarted:
            // Not started maps to backend_error in the .NET facade — the
            // facade doesn't have a separate "NotStarted" kind because
            // stop() is documented as idempotent. Unreachable in practice
            // unless a non-stop path raises notStarted (none today).
            kindStr = "backend_error"; code = 4
            details["underlying"] = "DVAIBridge has not been started."
        }
        return NSError(domain: domain, code: code, userInfo: [
            "kind": kindStr,
            "details": details,
            NSLocalizedDescriptionKey: e.localizedDescription,
        ])
    }
}

/// @objc-friendly Combine cancellable handle. The .NET binding consumes
/// this as `IDisposable` and calls `Cancel()` on dispose.
@objc(DVAIBridgeNetCancellable)
public final class CancellableHandle: NSObject {
    private var cancellable: AnyCancellable?

    init(cancellable: AnyCancellable) {
        self.cancellable = cancellable
    }

    @objc public func cancel() {
        cancellable?.cancel()
        cancellable = nil
    }
}
