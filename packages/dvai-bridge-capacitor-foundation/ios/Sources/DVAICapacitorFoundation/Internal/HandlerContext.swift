import Foundation

public struct HandlerContext: Sendable {
    public let modelId: String
    public let backendName: String

    public init(modelId: String, backendName: String) {
        self.modelId = modelId
        self.backendName = backendName
    }
}

public enum HandlerResponse {
    case json(Int, Any)
    case sse(AsyncStream<String>)
    case error(Int, String)
}

public protocol DVAIHandlers: Sendable {
    func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse
    func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse
    func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse
    func handleModels(ctx: HandlerContext) async throws -> HandlerResponse
}
