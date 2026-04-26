import Foundation

public struct BoundServer: Sendable, Equatable {
    public let baseUrl: String
    public let port: Int
    public let backend: BackendKind
    public let modelId: String

    public init(baseUrl: String, port: Int, backend: BackendKind, modelId: String) {
        self.baseUrl = baseUrl
        self.port = port
        self.backend = backend
        self.modelId = modelId
    }

    /// Construct from the underlying core PluginState's `[String: Any]` result.
    internal init(coreResult: [String: Any], backend: BackendKind) throws {
        guard let baseUrl = coreResult["baseUrl"] as? String,
              let port = (coreResult["port"] as? Int) ?? (coreResult["port"] as? NSNumber)?.intValue
        else {
            throw DVAIBridgeError.backendError(underlying: "core PluginState returned malformed start result")
        }
        let modelId = (coreResult["modelId"] as? String) ?? ""
        self.init(baseUrl: baseUrl, port: port, backend: backend, modelId: modelId)
    }
}
