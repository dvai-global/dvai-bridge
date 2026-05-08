import Foundation

public struct DVAIBridgeConfig: Sendable {
    public enum CORSOrigin: Sendable {
        case wildcard
        case exact(String)
        case allowlist([String])
    }

    public var backend: BackendKind
    public var modelPath: String?
    public var mmprojPath: String?
    public var tokenizerPath: String?
    public var gpuLayers: Int
    public var contextSize: Int
    public var threads: Int
    public var embeddingMode: Bool
    public var httpBasePort: Int
    public var httpMaxPortAttempts: Int
    public var corsOrigin: CORSOrigin
    public var autoUnloadOnLowMemory: Bool
    public var logLevel: String  // "silent" | "info" | "debug" — matches the Capacitor surface

    public init(
        backend: BackendKind = .auto,
        modelPath: String? = nil,
        mmprojPath: String? = nil,
        tokenizerPath: String? = nil,
        gpuLayers: Int = 99,
        contextSize: Int = 2048,
        threads: Int = 4,
        embeddingMode: Bool = false,
        httpBasePort: Int = 38883,
        httpMaxPortAttempts: Int = 16,
        corsOrigin: CORSOrigin = .wildcard,
        autoUnloadOnLowMemory: Bool = false,
        logLevel: String = "info"
    ) {
        self.backend = backend
        self.modelPath = modelPath
        self.mmprojPath = mmprojPath
        self.tokenizerPath = tokenizerPath
        self.gpuLayers = gpuLayers
        self.contextSize = contextSize
        self.threads = threads
        self.embeddingMode = embeddingMode
        self.httpBasePort = httpBasePort
        self.httpMaxPortAttempts = httpMaxPortAttempts
        self.corsOrigin = corsOrigin
        self.autoUnloadOnLowMemory = autoUnloadOnLowMemory
        self.logLevel = logLevel
    }

    /// v3.2 — copy with `httpBasePort` overridden. Used by the
    /// OffloadProxy lifecycle to push the backend off the user-facing
    /// port (proxy claims `httpBasePort`, backend gets `httpBasePort + 100`).
    public func with(httpBasePort newPort: Int) -> DVAIBridgeConfig {
        var copy = self
        copy.httpBasePort = newPort
        return copy
    }

    /// Translate this config into the `[String: Any]` shape the underlying
    /// core PluginStates expect (matches the Capacitor JSObject shape).
    internal func toCoreOpts() -> [String: Any] {
        var opts: [String: Any] = [
            "gpuLayers": gpuLayers,
            "contextSize": contextSize,
            "threads": threads,
            "embeddingMode": embeddingMode,
            "httpBasePort": httpBasePort,
            "httpMaxPortAttempts": httpMaxPortAttempts,
            "autoUnloadOnLowMemory": autoUnloadOnLowMemory,
            "logLevel": logLevel,
        ]
        if let modelPath { opts["modelPath"] = modelPath }
        if let mmprojPath { opts["mmprojPath"] = mmprojPath }
        if let tokenizerPath { opts["tokenizerPath"] = tokenizerPath }
        switch corsOrigin {
        case .wildcard: opts["corsOrigin"] = "*"
        case .exact(let s): opts["corsOrigin"] = s
        case .allowlist(let xs): opts["corsOrigin"] = xs
        }
        return opts
    }
}
