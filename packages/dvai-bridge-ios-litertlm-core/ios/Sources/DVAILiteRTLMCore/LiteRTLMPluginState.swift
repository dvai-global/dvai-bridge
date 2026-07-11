// LiteRTLMPluginState — lifecycle owner for the LiteRT-LM backend on iOS/macOS.
//
// Mirrors MLXPluginState's shape so the DVAIBridge umbrella can swap
// among .llama / .foundation / .coreml / .mlx / .litertlm with the
// same start/stop/status surface.
//
// Notes:
//   - `modelPath` opt is a filesystem path to a `.litertlm` file. Same
//     model files that run on our Android LiteRT-LM SDK — one weight
//     drop for both platforms.
//   - The LiteRT-LM runtime does its own worker offloading internally,
//     so we don't spawn any DispatchQueue here.
//   - Metal GPU by default; fall back to CPU by passing `accelerator: "cpu"`.
//   - Multi-turn OpenAI chat surfaces are stateless per request, but
//     LiteRT-LM's `Conversation` is stateful — we create a fresh one
//     per request and serialise the full messages history into a
//     Gemma-template prompt. Matches the pattern used by the JS
//     LiteRTLMBackend in @dvai-bridge/core.

import Foundation
#if !COCOAPODS
import DVAISharedCore
#endif
import LiteRTLM

public actor LiteRTLMPluginState {
    private var server: HttpServer?
    private var handlers: LiteRTLMHandlers?
    private var engine: Engine?
    private(set) var modelId: String = ""
    private(set) var isRunning: Bool = false
    private(set) var baseUrl: String?
    private(set) var port: Int?

    public init() {}

    public func start(opts: [String: Any]) async throws -> [String: Any] {
        if isRunning { try await stopInternal() }

        guard let modelPath = opts["modelPath"] as? String, !modelPath.isEmpty else {
            throw NSError(
                domain: "DVAIBridgeLiteRTLM",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "LiteRT-LM backend requires a `modelPath` option pointing to a .litertlm file."]
            )
        }

        let acceleratorOpt = (opts["accelerator"] as? String)?.lowercased() ?? "gpu"
        let backendKind: LiteRTLM.Backend = acceleratorOpt == "cpu" ? .cpu() : .gpu
        let cacheDir = opts["cacheDir"] as? String ?? NSTemporaryDirectory()

        let httpBasePort = opts["httpBasePort"] as? Int ?? 38883
        let httpMaxPortAttempts = opts["httpMaxPortAttempts"] as? Int ?? 16
        let corsRaw = opts["corsOrigin"]
        let corsConfig = parseCors(corsRaw)

        let engine: Engine
        do {
            let config = try EngineConfig(
                modelPath: modelPath,
                backend: backendKind,
                cacheDir: cacheDir
            )
            engine = Engine(engineConfig: config)
            try await engine.initialize()
        } catch {
            throw NSError(
                domain: "DVAIBridgeLiteRTLM",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "LiteRT-LM engine init failed for \(modelPath): \(error.localizedDescription)"]
            )
        }

        let handlers = LiteRTLMHandlers(modelId: modelPath, engine: engine)
        let ctx = HandlerContext(modelId: modelPath, backendName: "litertlm")
        let server = HttpServer()
        await server.installRoutes(handlers: handlers, ctx: ctx, corsConfig: corsConfig)

        let port = try await server.tryBind(
            basePort: httpBasePort,
            maxAttempts: httpMaxPortAttempts,
            host: "127.0.0.1"
        )

        self.engine = engine
        self.handlers = handlers
        self.modelId = modelPath
        self.server = server
        self.port = port
        self.baseUrl = "http://127.0.0.1:\(port)/v1"
        self.isRunning = true

        return [
            "baseUrl": self.baseUrl!,
            "port": port,
            "backend": "litertlm",
            "modelId": modelPath,
        ]
    }

    public func stop() async throws {
        try await stopInternal()
    }

    private func stopInternal() async throws {
        await server?.stop()
        server = nil
        handlers = nil
        engine = nil
        modelId = ""
        baseUrl = nil
        port = nil
        isRunning = false
    }

    public func statusInfo() -> [String: Any] {
        var dict: [String: Any] = ["running": isRunning]
        if let baseUrl = baseUrl { dict["baseUrl"] = baseUrl }
        if isRunning { dict["backend"] = "litertlm" }
        return dict
    }

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
