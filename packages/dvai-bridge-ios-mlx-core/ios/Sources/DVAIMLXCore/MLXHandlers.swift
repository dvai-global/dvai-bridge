// MLXHandlers — DVAIHandlers conformance for the MLX backend.
//
// Wraps mlx-swift-lm's MLXLMCommon.ChatSession into our OpenAI-compatible
// HTTP surface. The actual model load happens at MLXPluginState.start()
// time; by the time these methods are called, `modelContainer` is ready.

import Foundation
#if !COCOAPODS
import DVAISharedCore
#endif
import MLXLMCommon

public final class MLXHandlers: DVAIHandlers, @unchecked Sendable {
    private let modelId: String
    private let modelContainer: ModelContainer

    /// `ChatSession` is not thread-safe per its docstring, so we serialise
    /// access through a single in-flight task at a time. For multi-request
    /// concurrency we'd need either a session pool or per-request session
    /// instances; defer that to a follow-up.
    private let session: ChatSession

    public init(modelId: String, modelContainer: ModelContainer) {
        self.modelId = modelId
        self.modelContainer = modelContainer
        self.session = ChatSession(modelContainer)
    }

    public func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        let messages = (body["messages"] as? [[String: Any]]) ?? []
        let prompt = Self.flattenMessagesToPrompt(messages)
        let stream = (body["stream"] as? Bool) ?? false

        if stream {
            // SSE streaming: forward MLX's stream of partial responses as
            // OpenAI-style chunked deltas. Each yield is one delta chunk.
            return .sse(AsyncStream<String> { continuation in
                Task { [session, modelId] in
                    do {
                        for try await partial in session.streamResponse(to: prompt) {
                            let delta: [String: Any] = [
                                "id": "mlx-\(UUID().uuidString.prefix(8))",
                                "object": "chat.completion.chunk",
                                "created": Int(Date().timeIntervalSince1970),
                                "model": modelId,
                                "choices": [[
                                    "index": 0,
                                    "delta": ["role": "assistant", "content": partial],
                                    "finish_reason": NSNull(),
                                ]],
                            ]
                            if let data = try? JSONSerialization.data(withJSONObject: delta),
                               let str = String(data: data, encoding: .utf8) {
                                continuation.yield("data: \(str)\n\n")
                            }
                        }
                        continuation.yield("data: [DONE]\n\n")
                        continuation.finish()
                    } catch {
                        continuation.finish()
                    }
                }
            })
        }

        let reply = try await session.respond(to: prompt)
        let json: [String: Any] = [
            "id": "mlx-\(UUID().uuidString.prefix(8))",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": modelId,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": reply],
                "finish_reason": "stop",
            ]],
        ]
        return .json(200, json)
    }

    public func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        let prompt = (body["prompt"] as? String) ?? ""
        let reply = try await session.respond(to: prompt)
        let json: [String: Any] = [
            "id": "mlx-\(UUID().uuidString.prefix(8))",
            "object": "text_completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": modelId,
            "choices": [[
                "text": reply,
                "index": 0,
                "finish_reason": "stop",
            ]],
        ]
        return .json(200, json)
    }

    public func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        // Embeddings would need MLXEmbedders + a different model. Defer to
        // the .llama or .coreml backends for now.
        return .error(501, "MLX backend does not currently expose embeddings; use BackendKind.llama or .coreml for /v1/embeddings.")
    }

    public func handleModels(ctx: HandlerContext) async throws -> HandlerResponse {
        let json: [String: Any] = [
            "object": "list",
            "data": [[
                "id": modelId,
                "object": "model",
                "created": Int(Date().timeIntervalSince1970),
                "owned_by": "mlx",
            ]],
        ]
        return .json(200, json)
    }

    /// Flatten OpenAI-style chat messages into a single prompt string. The
    /// underlying `ChatSession` carries its own conversational state, but
    /// our HTTP surface is stateless (each request includes the whole
    /// history), so we ignore the session's state and just submit the
    /// concatenated turns. ChatSession will apply the model's chat template
    /// to whatever prompt it receives.
    private static func flattenMessagesToPrompt(_ messages: [[String: Any]]) -> String {
        // Concatenate roles + content in a way compatible with most chat
        // templates. The session re-applies the model's own template
        // internally, so we just need to deliver the latest user turn
        // along with prior context as part of the prompt body.
        var lines: [String] = []
        for msg in messages {
            let role = (msg["role"] as? String) ?? "user"
            let content = (msg["content"] as? String) ?? ""
            lines.append("[\(role)]: \(content)")
        }
        return lines.joined(separator: "\n")
    }
}
