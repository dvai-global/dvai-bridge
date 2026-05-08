import Foundation
import CoreML
#if !COCOAPODS
import DVAISharedCore   // HttpServer, DVAIHandlers, HandlerContext, CORSConfig
#endif

/// Public PluginState mirroring DVAILlamaCore.PluginState's shape.
/// Boots a Telegraph HTTP server on `127.0.0.1:<port>` (with port-fallback),
/// loads the .mlmodelc model + tokenizer, and serves OpenAI-compatible
/// requests via CoreMLHandlers.
///
/// Requires iOS 18 / macOS 15 for MLState (KV-cache stateful decoding).
@available(iOS 18.0, macOS 15.0, *)
public actor CoreMLPluginState {
    private var httpServer: HttpServer?
    private var generator: CoreMLGenerator?
    private var modelId: String = ""
    private var isRunning: Bool = false
    private var baseUrl: String?
    private var port: Int?

    public init() {}

    public func start(opts: [String: Any]) async throws -> [String: Any] {
        if isRunning { try await stop() }

        guard let modelPath = opts["modelPath"] as? String, !modelPath.isEmpty else {
            throw CoreMLBackendError.modelLoadFailed(
                reason: "modelPath is required for the CoreML backend")
        }
        guard let tokenizerPath = opts["tokenizerPath"] as? String, !tokenizerPath.isEmpty else {
            throw CoreMLBackendError.tokenizerLoadFailed(
                reason: "tokenizerPath is required (path to a directory containing " +
                        "tokenizer.json + tokenizer_config.json)")
        }

        let modelURL = URL(fileURLWithPath: modelPath)
        let tokenizerDir = URL(fileURLWithPath: tokenizerPath)

        // Optional opts with defaults — match Apple's stateful Llama-3.2
        // conversion conventions (snake_case, matching HF / PyTorch).
        let inputName = (opts["coremlInputName"] as? String) ?? "input_ids"
        let causalMaskName = (opts["coremlCausalMaskName"] as? String) ?? "causal_mask"
        let outputName = (opts["coremlOutputName"] as? String) ?? "logits"
        let maxContextTokens = (opts["contextSize"] as? Int) ?? 2048
        let temperature = (opts["temperature"] as? Double).map(Float.init) ?? 0.0
        let topP = (opts["topP"] as? Double).map(Float.init) ?? 1.0
        let topK = (opts["topK"] as? Int) ?? 0
        let maxNewTokens = (opts["maxNewTokens"] as? Int) ?? 512
        let httpBasePort = (opts["httpBasePort"] as? Int) ?? 38883
        let httpMaxPortAttempts = (opts["httpMaxPortAttempts"] as? Int) ?? 16

        // Load tokenizer first — its eosTokenId is needed by the engine.
        let tokenizer = try await CoreMLTokenizer(tokenizerDir: tokenizerDir)
        let engine = try CoreMLEngine(
            modelURL: modelURL,
            inputName: inputName,
            causalMaskName: causalMaskName,
            outputName: outputName,
            maxContextTokens: maxContextTokens,
            eosTokenId: tokenizer.eosTokenId
        )

        let sampler = CoreMLSampler(temperature: temperature, topP: topP, topK: topK)
        let gen = CoreMLGenerator(
            engine: engine,
            tokenizer: tokenizer,
            sampler: sampler,
            maxNewTokens: maxNewTokens
        )

        let modelIdValue = modelURL.deletingPathExtension().lastPathComponent
        let handlers = CoreMLHandlers(generator: gen, modelId: modelIdValue)

        // Build context + cors first, install routes, THEN bind —
        // Hummingbird requires routes at Application construction time
        // so the install → bind order is mandatory.
        let ctx = HandlerContext(modelId: modelIdValue, backendName: "coreml")
        // Note: plan used DispatchConfig which doesn't exist in DVAILlamaCore.
        // Real type is CORSConfig (public). parseCors() below maps opts → CORSConfig.
        let corsConfig = parseCors(opts["corsOrigin"])
        let server = HttpServer()
        await server.installRoutes(handlers: handlers, ctx: ctx, corsConfig: corsConfig)

        let boundPort = try await server.tryBind(
            basePort: httpBasePort,
            maxAttempts: httpMaxPortAttempts,
            host: "127.0.0.1"
        )

        self.httpServer = server
        self.generator = gen
        self.modelId = modelIdValue
        self.port = boundPort
        self.baseUrl = "http://127.0.0.1:\(boundPort)/v1"
        self.isRunning = true

        return [
            "baseUrl": self.baseUrl!,
            "port": boundPort,
            "backend": "coreml",
            "modelId": modelIdValue,
        ]
    }

    public func stop() async throws {
        await httpServer?.stop()
        httpServer = nil
        generator = nil
        modelId = ""
        baseUrl = nil
        port = nil
        isRunning = false
    }

    public func statusInfo() -> [String: Any] {
        var dict: [String: Any] = ["running": isRunning]
        if let baseUrl = baseUrl { dict["baseUrl"] = baseUrl }
        if isRunning { dict["backend"] = "coreml" }
        return dict
    }

    // MARK: - Private

    private func parseCors(_ raw: Any?) -> CORSConfig {
        if let s = raw as? String { return s == "*" ? .wildcard : .exact(s) }
        if let arr = raw as? [String] { return .allowlist(arr) }
        return .wildcard
    }
}
