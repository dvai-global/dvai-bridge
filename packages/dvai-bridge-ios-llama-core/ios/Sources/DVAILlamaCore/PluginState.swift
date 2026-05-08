// Internal/PluginState.swift
import Foundation
#if !COCOAPODS
import DVAILlamaCoreObjC
#endif
#if !COCOAPODS
import DVAISharedCore
#endif

/// Owns the running state of the capacitor-llama plugin: the model bridge,
/// the HTTP server, and the model metadata. All access is serialised through
/// the actor isolation.
public actor PluginState {
    private var server: HttpServer?
    private var bridge: LlamaCppBridge?
    private(set) var modelId: String = ""
    private(set) var isRunning: Bool = false
    private(set) var baseUrl: String?
    private(set) var port: Int?

    public init() {}

    /// Start the plugin: load model, bind server, install routes.
    /// - Returns dictionary suitable for Capacitor's `call.resolve(...)`.
    public func start(opts: [String: Any]) async throws -> [String: Any] {
        if isRunning { try await stopInternal() }

        guard let modelPath = opts["modelPath"] as? String, !modelPath.isEmpty else {
            throw NSError(
                domain: "DVAIBridgeLlama",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "modelPath is required for llama backend"]
            )
        }

        let mmprojPath = opts["mmprojPath"] as? String
        let chatTemplate = opts["chatTemplate"] as? String
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

        // Phase 2A Pass 2: load mmproj (if provided) so multimodal handlers
        // can light up. A failed mmproj load is fatal for this start() call —
        // the caller asked for a multimodal model and we couldn't deliver.
        if let mmprojPath = mmprojPath, !mmprojPath.isEmpty {
            do {
                try bridge.loadMmproj(atPath: mmprojPath)
            } catch {
                bridge.unload()
                throw error
            }
        }
        let mmprojLoaded = bridge.isMmprojLoaded
        // Audio encoder support implies mmproj is loaded AND mtmd reports
        // an audio encoder is present in the projector.
        let modelHasAudioEncoder = mmprojLoaded && bridge.hasAudioEncoder()

        // Build handlers + context first; Hummingbird requires routes
        // to be registered at Application construction time, so the
        // installRoutes → tryBind order is mandatory. Phase 2A Pass 2:
        // real flags mirrored from the bridge state. embeddingMode
        // comes straight from the start opts so /v1/embeddings can
        // short-circuit when off. chatTemplate is an optional
        // Jinja-compatible override; nil/empty falls through to the
        // model's bundled `tokenizer.chat_template`.
        let handlers = LlamaHandlers(
            bridge: bridge,
            modelId: modelPath,
            mmprojLoaded: mmprojLoaded,
            modelHasAudioEncoder: modelHasAudioEncoder,
            embeddingMode: embeddingMode,
            chatTemplate: chatTemplate
        )
        let ctx = HandlerContext(modelId: modelPath, backendName: "llama")
        let server = HttpServer()
        await server.installRoutes(handlers: handlers, ctx: ctx, corsConfig: corsConfig)

        // Bind server (with port-fallback). If bind fails, release the
        // bridge so the loaded llama context doesn't leak until next
        // start().
        let port: Int
        do {
            port = try await server.tryBind(
                basePort: httpBasePort,
                maxAttempts: httpMaxPortAttempts,
                host: "127.0.0.1"
            )
        } catch {
            bridge.unload()
            throw error
        }

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
    public func stop() async throws {
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
    public func statusInfo() -> [String: Any] {
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
