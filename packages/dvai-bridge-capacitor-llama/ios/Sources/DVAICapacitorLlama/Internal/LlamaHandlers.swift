// Internal/LlamaHandlers.swift
import Foundation
import DVAICapacitorLlamaObjC

/// Stub implementation. Task 36 replaces all four handler methods with real
/// llama.cpp calls. For Task 28's lifecycle test, `handleModels` returns the
/// canned model list and the other three return 501.
public final class LlamaHandlers: DVAIHandlers, @unchecked Sendable {
    private let bridge: LlamaCppBridge
    private let modelId: String

    public init(bridge: LlamaCppBridge, modelId: String) {
        self.bridge = bridge
        self.modelId = modelId
    }

    public func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(501, ["error": "Not implemented yet — Task 36"])
    }

    public func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(501, ["error": "Not implemented yet — Task 36"])
    }

    public func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(501, ["error": "Not implemented yet — Task 36"])
    }

    public func handleModels(ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(200, [
            "object": "list",
            "data": [["id": ctx.modelId, "object": "model", "owned_by": "dvai-bridge"]],
        ])
    }
}
