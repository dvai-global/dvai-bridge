// DVAIBridgeFlutterPlugin — Swift entry point for the `dvai_bridge`
// Flutter plugin.
//
// Architecture:
//
//   - Implements the Pigeon-generated `DVAIBridgeHostApi` protocol (4 lifecycle
//     methods). Each method opens a `Task { ... }`, awaits the underlying
//     `DVAIBridge.shared` actor, and bridges the result back to Pigeon's
//     completion handler. This is the documented pattern from the Phase 3F
//     spec §6 question 9 — Pigeon doesn't generate `actor` methods directly
//     (as of 26.3.4), so we wrap.
//
//   - Subscribes to `DVAIBridge.shared.progressPublisher` (Combine) on first
//     listener and pumps events through the Pigeon-generated event channel
//     (`ProgressEventsStreamHandler`).
//
//   - Translates Swift's `DVAIBridgeError` cases into Pigeon `PigeonError`
//     instances whose `code` field uses the same lowercase camelCase wire
//     identifier as the Dart enum (`DVAIBridgeErrorKind.wireValue`). The
//     Dart facade decodes back via `DVAIBridgeError.fromPlatform(...)`.
//
// The plugin instance lifetime is tied to the Flutter engine. Multiple
// engines (e.g. add-to-app scenarios with `FlutterEngineGroup`) each get
// their own `DVAIBridgeFlutterPlugin` instance and their own progress
// subscription, but they share the singleton `DVAIBridge.shared` actor —
// the Phase 3C SDK's design.

import Combine
import Flutter
import Foundation
import UIKit

import DVAIBridge

public final class DVAIBridgeFlutterPlugin: NSObject, FlutterPlugin, DVAIBridgeHostApi {
  /// Combine subscription to `DVAIBridge.shared.progressPublisher`. Held as
  /// a property so the plugin instance retains it for its lifetime; the
  /// stream handler installs/replaces it on `onListen`.
  private var progressCancellable: AnyCancellable?

  /// Strong reference to the Pigeon stream handler so its lifetime matches
  /// the plugin instance (Flutter doesn't retain stream handlers itself).
  private var progressStreamHandler: ProgressStreamHandler?

  public static func register(with registrar: any FlutterPluginRegistrar) {
    let plugin = DVAIBridgeFlutterPlugin()
    DVAIBridgeHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: plugin)

    let streamHandler = ProgressStreamHandler()
    plugin.progressStreamHandler = streamHandler
    ProgressEventsStreamHandler.register(
      with: registrar.messenger(),
      streamHandler: streamHandler
    )
  }

  // MARK: - DVAIBridgeHostApi

  public func startBridge(
    opts: StartOptionsMessage,
    completion: @escaping (Result<BoundServerMessage, Error>) -> Void
  ) {
    Task {
      do {
        let config = try DVAIBridgeFlutterPlugin.makeConfig(from: opts)
        let server = try await DVAIBridge.shared.start(config)
        completion(.success(DVAIBridgeFlutterPlugin.toMessage(server)))
      } catch let bridgeError as DVAIBridgeError {
        completion(.failure(DVAIBridgeFlutterPlugin.toPigeonError(bridgeError)))
      } catch {
        completion(.failure(PigeonError(
          code: "backendError",
          message: error.localizedDescription,
          details: nil
        )))
      }
    }
  }

  public func stopBridge(completion: @escaping (Result<Void, Error>) -> Void) {
    Task {
      do {
        try await DVAIBridge.shared.stop()
        completion(.success(()))
      } catch let bridgeError as DVAIBridgeError {
        completion(.failure(DVAIBridgeFlutterPlugin.toPigeonError(bridgeError)))
      } catch {
        completion(.failure(PigeonError(
          code: "backendError",
          message: error.localizedDescription,
          details: nil
        )))
      }
    }
  }

  public func status(
    completion: @escaping (Result<StatusInfoMessage, Error>) -> Void
  ) {
    Task {
      let info = await DVAIBridge.shared.status()
      completion(.success(StatusInfoMessage(
        running: info.running,
        baseUrl: info.baseUrl,
        port: nil,
        backend: info.backend?.rawValue,
        modelId: nil
      )))
    }
  }

  public func downloadModel(
    opts: DownloadOptionsMessage,
    completion: @escaping (Result<DownloadResultMessage, Error>) -> Void
  ) {
    Task {
      do {
        guard let url = URL(string: opts.url) else {
          throw DVAIBridgeError.configurationInvalid(reason: "Invalid URL: \(opts.url)")
        }
        var headers: [String: String] = [:]
        if let pairs = opts.headers {
          var index = 0
          while index + 1 < pairs.count {
            if let key = pairs[index], let value = pairs[index + 1] {
              headers[key] = value
            }
            index += 2
          }
        }
        let downloadOpts = DVAIBridge.DownloadOptions(
          url: url,
          sha256: opts.sha256,
          destFilename: opts.destFilename,
          headers: headers
        )
        let result = try await DVAIBridge.shared.downloadModel(downloadOpts)
        // The iOS DVAIBridge.DownloadResult exposes `path` + `cached` only;
        // sha256 / sizeBytes aren't surfaced, so echo the request's sha256
        // and 0 bytes so the cross-platform shape stays consistent. The
        // Android side fills in the real numbers; iOS-side smoke tests for
        // those fields can read them off-band via Foundation if needed.
        completion(.success(DownloadResultMessage(
          path: result.path,
          sha256: opts.sha256,
          sizeBytes: 0,
          cached: result.cached
        )))
      } catch let bridgeError as DVAIBridgeError {
        completion(.failure(DVAIBridgeFlutterPlugin.toPigeonError(bridgeError)))
      } catch {
        completion(.failure(PigeonError(
          code: "downloadFailed",
          message: error.localizedDescription,
          details: nil
        )))
      }
    }
  }

  public func assessHardware(
    hardwareMinimum: Double,
    minLocalCapability: Double,
    completion: @escaping (Result<HardwareAssessmentMessage, Error>) -> Void
  ) {
    let a = DVAIBridge.shared.assessHardware(
      hardwareMinimum: hardwareMinimum,
      minLocalCapability: minLocalCapability
    )
    completion(.success(HardwareAssessmentMessage(
      mode: a.mode.rawValue,
      tokPerSec: a.tokPerSec,
      reason: a.reason,
      hasNpu: a.hints.hasNpu,
      ramGb: Int64(a.hints.ramGb),
      gpuClass: a.hints.gpuClass.rawValue,
      cpuClass: a.hints.cpuClass.rawValue
    )))
  }

  // MARK: - Translation helpers

  private static func makeConfig(from msg: StartOptionsMessage) throws -> DVAIBridgeConfig {
    guard let backend = BackendKind(rawValue: msg.backend) else {
      throw DVAIBridgeError.configurationInvalid(reason: "Unknown backend \(msg.backend)")
    }
    let cors: DVAIBridgeConfig.CORSOrigin
    if let raw = msg.corsOrigin {
      if raw == "*" {
        cors = .wildcard
      } else if raw.contains(",") {
        let allowlist = raw
          .split(separator: ",")
          .map { String($0).trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
        cors = .allowlist(allowlist)
      } else {
        cors = .exact(raw)
      }
    } else {
      cors = .wildcard
    }
    return DVAIBridgeConfig(
      backend: backend,
      modelPath: msg.modelPath,
      mmprojPath: msg.mmprojPath,
      tokenizerPath: msg.tokenizerPath,
      gpuLayers: msg.gpuLayers.map(Int.init) ?? 99,
      contextSize: msg.contextSize.map(Int.init) ?? 2048,
      threads: msg.threads.map(Int.init) ?? 4,
      embeddingMode: msg.embeddingMode ?? false,
      httpBasePort: msg.httpBasePort.map(Int.init) ?? 38883,
      httpMaxPortAttempts: msg.httpMaxPortAttempts.map(Int.init) ?? 16,
      corsOrigin: cors,
      autoUnloadOnLowMemory: msg.autoUnloadOnLowMemory ?? false,
      logLevel: msg.logLevel ?? "info"
    )
  }

  private static func toMessage(_ server: BoundServer) -> BoundServerMessage {
    return BoundServerMessage(
      baseUrl: server.baseUrl,
      port: Int64(server.port),
      backend: server.backend.rawValue,
      modelId: server.modelId
    )
  }

  private static func toPigeonError(_ error: DVAIBridgeError) -> PigeonError {
    let code: String
    var details: [String: Any]? = nil
    switch error {
    case .alreadyStarted(let backend, let baseUrl):
      code = "alreadyStarted"
      details = ["backend": backend.rawValue, "baseUrl": baseUrl]
    case .notStarted:
      code = "notStarted"
    case .configurationInvalid:
      code = "configurationInvalid"
    case .backendUnavailable(let backend, _):
      code = "backendUnavailable"
      details = ["backend": backend.rawValue]
    case .modelLoadFailed:
      code = "modelLoadFailed"
    case .downloadFailed:
      code = "downloadFailed"
    case .checksumMismatch:
      code = "checksumMismatch"
    case .backendError:
      code = "backendError"
    }
    return PigeonError(
      code: code,
      message: error.errorDescription,
      details: details
    )
  }

  // MARK: - Progress event channel

  /// Stream handler for the Pigeon `progressEvents` event channel. Subscribes
  /// to `DVAIBridge.shared.progressPublisher` on first listener and replays
  /// events as `ProgressEventMessage` payloads. Cancels on `onCancel`.
  final class ProgressStreamHandler: PigeonEventChannelWrapper<ProgressEventMessage> {
    private var cancellable: AnyCancellable?

    override func onListen(
      withArguments arguments: Any?,
      sink: PigeonEventSink<ProgressEventMessage>
    ) {
      cancellable?.cancel()
      cancellable = DVAIBridge.shared.progressPublisher.sink { event in
        sink.success(ProgressStreamHandler.toMessage(event))
      }
    }

    override func onCancel(withArguments arguments: Any?) {
      cancellable?.cancel()
      cancellable = nil
    }

    /// Translate the iOS-side `ProgressEvent` into the Pigeon wire shape.
    /// The iOS SDK currently emits `Phase` only (no `kind`), so we infer
    /// `kind` from the phase: `error` → failed, `ready` → completed
    /// (post-start), `verify` → completed (post-download), and the rest →
    /// progress. The Android side already emits explicit kinds, so the
    /// Dart facade gets a uniform shape across both platforms.
    static func toMessage(_ event: ProgressEvent) -> ProgressEventMessage {
      let phase = event.phase.rawValue
      let kind: String
      switch event.phase {
      case .ready:
        kind = "completed"
      case .error:
        kind = "failed"
      case .verify:
        kind = "completed"
      case .download, .load:
        kind = "progress"
      }
      return ProgressEventMessage(
        kind: kind,
        phase: phase,
        percent: event.percent,
        message: event.message,
        errorKind: event.phase == .error ? "backendError" : nil,
        errorMessage: event.phase == .error ? event.message : nil
      )
    }
  }
}
