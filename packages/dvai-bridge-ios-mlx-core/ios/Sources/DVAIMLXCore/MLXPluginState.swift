// MLXPluginState — lifecycle owner for the MLX backend.
//
// Mirrors FoundationPluginState's shape so DVAIBridge can swap among
// .llama / .foundation / .coreml / .mlx backends with the same
// start/stop/status surface.
//
// Notes:
//   - MLX requires Apple Silicon at runtime; we don't gate that here
//     because the underlying mlx-swift framework returns a clean error if
//     the GPU is unavailable.
//   - `modelPath` opt is a HuggingFace model id (e.g.
//     "mlx-community/Llama-3.2-1B-Instruct-4bit"). The first call
//     downloads weights into the user's HF cache; subsequent calls
//     reuse them. Local-directory loads are a Phase 3D follow-up
//     (the mlx-swift-lm 2.x convenience API takes only an HF id).

import Foundation
#if !COCOAPODS
import DVAISharedCore
#endif
import MLXLMCommon
// MLXLLM registers `LLMModelFactory` with the global ModelFactoryRegistry
// at load time. We never reference its types directly (loadModelContainer
// finds the factory via NSClassFromString → TrampolineModelFactory), but
// the import is required so the linker keeps its objects in the binary.
@_implementationOnly import MLXLLM

public actor MLXPluginState {
    private var server: HttpServer?
    private var handlers: MLXHandlers?
    private(set) var modelId: String = ""
    private(set) var isRunning: Bool = false
    private(set) var baseUrl: String?
    private(set) var port: Int?

    public init() {}

    public func start(opts: [String: Any]) async throws -> [String: Any] {
        if isRunning { try await stopInternal() }

        // Required: HF model id, e.g. "mlx-community/Llama-3.2-1B-Instruct-4bit".
        guard let modelPath = opts["modelPath"] as? String, !modelPath.isEmpty else {
            throw NSError(
                domain: "DVAIBridgeMLX",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "MLX backend requires a `modelPath` option (HuggingFace model id, e.g. \"mlx-community/Llama-3.2-1B-Instruct-4bit\")."]
            )
        }

        let httpBasePort = opts["httpBasePort"] as? Int ?? 38883
        let httpMaxPortAttempts = opts["httpMaxPortAttempts"] as? Int ?? 16
        let corsRaw = opts["corsOrigin"]
        let corsConfig = parseCors(corsRaw)

        // Load the model from HF (cached on subsequent runs). This is the
        // expensive call — can take 30–120s for first download depending
        // on size and network; instant on cache hits.
        let modelContainer: ModelContainer
        do {
            modelContainer = try await loadModelContainer(id: modelPath)
        } catch {
            throw NSError(
                domain: "DVAIBridgeMLX",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "MLX model load failed for \(modelPath): \(error.localizedDescription)"]
            )
        }

        let server = HttpServer()
        let port = try await server.tryBind(
            basePort: httpBasePort,
            maxAttempts: httpMaxPortAttempts,
            host: "127.0.0.1"
        )

        let handlers = MLXHandlers(modelId: modelPath, modelContainer: modelContainer)
        let ctx = HandlerContext(modelId: modelPath, backendName: "mlx")
        await server.installRoutes(handlers: handlers, ctx: ctx, corsConfig: corsConfig)

        self.handlers = handlers
        self.modelId = modelPath
        self.server = server
        self.port = port
        self.baseUrl = "http://127.0.0.1:\(port)/v1"
        self.isRunning = true

        return [
            "baseUrl": self.baseUrl!,
            "port": port,
            "backend": "mlx",
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
        modelId = ""
        baseUrl = nil
        port = nil
        isRunning = false
    }

    public func statusInfo() -> [String: Any] {
        var dict: [String: Any] = ["running": isRunning]
        if let baseUrl = baseUrl { dict["baseUrl"] = baseUrl }
        if isRunning { dict["backend"] = "mlx" }
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
