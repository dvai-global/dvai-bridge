// Internal/PluginState.swift
//
// Owns the running state of the capacitor-foundation plugin: the embedded
// HTTP server and the FoundationHandlers instance. All access is serialised
// through actor isolation.
//
// Differences from capacitor-llama's PluginState:
//   - No model bridge: Apple FM owns the model inside `LanguageModelSession`,
//     so there is no `LlamaCppBridge` analogue.
//   - No `modelPath` opt: the system model is implicit.
//   - iOS 26.0+ runtime gate: FoundationHandlers is `@available(iOS 26.0,
//     macOS 26.0, *)`. We must check at runtime AND at the compiler level
//     (the inner `#available` is required so the compiler permits us to
//     instantiate FoundationHandlers).
//   - No embeddingMode/mmprojPath/gpuLayers/contextSize/threads opts:
//     Apple FM does not expose any of those knobs.

import Foundation

actor PluginState {
    private var server: HttpServer?
    /// Type-erased reference to the live `FoundationHandlers` instance.
    /// Stored as `AnyObject?` rather than `FoundationHandlers?` so we
    /// don't have to mark the entire actor `@available(iOS 26.0, *)` —
    /// the concrete type is only ever materialised inside an `#available`
    /// block in `start()`. We never need to call methods on it from here
    /// (Telegraph holds the only callable reference, via `installRoutes`),
    /// so a strong-but-opaque retain is sufficient.
    private var handlers: AnyObject?
    private(set) var modelId: String = "apple-foundation-3b"
    private(set) var isRunning: Bool = false
    private(set) var baseUrl: String?
    private(set) var port: Int?

    /// Start the plugin: gate on iOS 26.0+, bind server, install routes.
    /// - Returns dictionary suitable for Capacitor's `call.resolve(...)`.
    func start(opts: [String: Any]) async throws -> [String: Any] {
        if isRunning { try await stopInternal() }

        // Compile-time guard: on hosts where the FoundationModels framework
        // isn't available at all (older Xcode), we can't run.
        #if !canImport(FoundationModels)
        throw NSError(
            domain: "DVAIBridgeFoundation",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "FoundationModels framework not available on this build."]
        )
        #else
        // Runtime gate: even if the framework is linkable, the iOS device
        // must be on iOS 26.0+ for the `LanguageModelSession` symbols to
        // exist. This is the user-facing error path for older devices.
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw NSError(
                domain: "DVAIBridgeFoundation",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Apple Foundation Models requires iOS 26.0 or later. The capacitor-foundation backend cannot start on this device."]
            )
        }

        let httpBasePort = opts["httpBasePort"] as? Int ?? 38883
        let httpMaxPortAttempts = opts["httpMaxPortAttempts"] as? Int ?? 16
        let corsRaw = opts["corsOrigin"]
        let corsConfig = parseCors(corsRaw)
        let modelIdOverride = opts["modelId"] as? String
        let modelId = modelIdOverride ?? "apple-foundation-3b"

        // Bind server with port-fallback (mirrors capacitor-llama).
        let server = HttpServer()
        let port = try await server.tryBind(
            basePort: httpBasePort,
            maxAttempts: httpMaxPortAttempts,
            host: "127.0.0.1"
        )

        let handlers = FoundationHandlers(modelId: modelId)
        let ctx = HandlerContext(modelId: modelId, backendName: "foundation")
        await server.installRoutes(handlers: handlers, ctx: ctx, corsConfig: corsConfig)

        self.handlers = handlers
        self.modelId = modelId
        self.server = server
        self.port = port
        self.baseUrl = "http://127.0.0.1:\(port)/v1"
        self.isRunning = true

        return [
            "baseUrl": self.baseUrl!,
            "port": port,
            "backend": "foundation",
            "modelId": modelId,
        ]
        #endif
    }

    /// Stop the plugin: drop handlers, stop server. Idempotent.
    func stop() async throws {
        try await stopInternal()
    }

    private func stopInternal() async throws {
        await server?.stop()
        server = nil
        handlers = nil
        modelId = "apple-foundation-3b"
        baseUrl = nil
        port = nil
        isRunning = false
    }

    /// Snapshot of the current running state, suitable for `call.resolve(...)`.
    func statusInfo() -> [String: Any] {
        var dict: [String: Any] = ["running": isRunning]
        if let baseUrl = baseUrl { dict["baseUrl"] = baseUrl }
        if isRunning { dict["backend"] = "foundation" }
        return dict
    }

    /// Parse the CORS option from the start opts dict.
    private func parseCors(_ raw: Any?) -> CORSConfig {
        if let s = raw as? String {
            return s == "*" ? .wildcard : .exact(s)
        }
        if let arr = raw as? [String] {
            return .allowlist(arr)
        }
        return .wildcard
    }
}
