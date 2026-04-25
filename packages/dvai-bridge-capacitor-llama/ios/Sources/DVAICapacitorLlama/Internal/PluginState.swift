// Internal/PluginState.swift
import Foundation
import DVAICapacitorLlamaObjC

/// Owns the running state of the capacitor-llama plugin: the model bridge,
/// the HTTP server, and the model metadata. All access is serialised through
/// the actor isolation.
actor PluginState {
    private var server: HttpServer?
    private var bridge: LlamaCppBridge?
    private(set) var modelId: String = ""
    private(set) var isRunning: Bool = false
    private(set) var baseUrl: String?
    private(set) var port: Int?

    /// Start the plugin: load model, bind server, install routes.
    /// - Returns dictionary suitable for Capacitor's `call.resolve(...)`.
    func start(opts: [String: Any]) async throws -> [String: Any] {
        if isRunning { try await stopInternal() }

        guard let modelPath = opts["modelPath"] as? String, !modelPath.isEmpty else {
            throw NSError(
                domain: "DVAIBridgeLlama",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "modelPath is required for llama backend"]
            )
        }

        let mmprojPath = opts["mmprojPath"] as? String
        let gpuLayers = opts["gpuLayers"] as? Int ?? 99
        let contextSize = opts["contextSize"] as? Int ?? 2048
        let threads = opts["threads"] as? Int ?? 4
        let embeddingMode = opts["embeddingMode"] as? Bool ?? false
        let httpBasePort = opts["httpBasePort"] as? Int ?? 38883
        let httpMaxPortAttempts = opts["httpMaxPortAttempts"] as? Int ?? 16
        let corsRaw = opts["corsOrigin"]
        let corsConfig = parseCors(corsRaw)

        // Load model via the ObjC++ bridge (real llama.cpp under the hood).
        let bridge = LlamaCppBridge()
        try bridge.loadModel(
            atPath: modelPath,
            mmprojPath: mmprojPath,
            gpuLayers: Int32(gpuLayers),
            contextSize: Int32(contextSize),
            threads: Int32(threads),
            embeddingMode: embeddingMode
        )

        // Bind server (with port-fallback)
        let server = HttpServer()
        let port = try await server.tryBind(
            basePort: httpBasePort,
            maxAttempts: httpMaxPortAttempts,
            host: "127.0.0.1"
        )

        // Install routes. Phase 1: mmproj / audio-encoder gates stay false until
        // the corresponding loaders land in Phase 2; embeddingMode is mirrored
        // from the start opts so /v1/embeddings can short-circuit when off.
        let handlers = LlamaHandlers(
            bridge: bridge,
            modelId: modelPath,
            mmprojLoaded: false,
            modelHasAudioEncoder: false,
            embeddingMode: embeddingMode
        )
        let ctx = HandlerContext(modelId: modelPath, backendName: "llama")
        await server.installRoutes(handlers: handlers, ctx: ctx, corsConfig: corsConfig)

        self.bridge = bridge
        self.server = server
        self.modelId = modelPath
        self.port = port
        self.baseUrl = "http://127.0.0.1:\(port)/v1"
        self.isRunning = true

        return [
            "baseUrl": self.baseUrl!,
            "port": port,
            "backend": "llama",
            "modelId": modelPath,
        ]
    }

    /// Stop the plugin: release model, stop server.
    func stop() async throws {
        try await stopInternal()
    }

    private func stopInternal() async throws {
        await server?.stop()
        bridge?.unload()
        server = nil
        bridge = nil
        modelId = ""
        baseUrl = nil
        port = nil
        isRunning = false
    }

    /// Snapshot of the current running state, suitable for Capacitor `call.resolve(...)`.
    func statusInfo() -> [String: Any] {
        var dict: [String: Any] = ["running": isRunning]
        if let baseUrl = baseUrl { dict["baseUrl"] = baseUrl }
        if isRunning { dict["backend"] = "llama" }
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
