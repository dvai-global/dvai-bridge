// LiteRTLMHandlers — DVAIHandlers conformance for the LiteRT-LM backend.
//
// Wraps LiteRT-LM's Conversation.sendMessage / sendMessageStream into
// the OpenAI-compatible surface consumers point their SDKs at.

import Foundation
#if !COCOAPODS
import DVAISharedCore
#endif
import LiteRTLM

public final class LiteRTLMHandlers: DVAIHandlers, @unchecked Sendable {
    private let modelId: String
    private let engine: Engine

    public init(modelId: String, engine: Engine) {
        self.modelId = modelId
        self.engine = engine
    }

    public func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        let messages = (body["messages"] as? [[String: Any]]) ?? []
        let prompt = Self.flattenMessagesToPrompt(messages)
        let stream = (body["stream"] as? Bool) ?? false

        // LiteRT-LM's Conversation is stateful; we create one per request
        // to match OpenAI's stateless chat completion surface.
        let conversation = try await engine.createConversation()
        let message = Message(prompt)

        if stream {
            return .sse(AsyncStream<String> { continuation in
                Task { [modelId] in
                    do {
                        for try await partial in conversation.sendMessageStream(message) {
                            let text = partial.toString
                            if text.isEmpty { continue }
                            let delta: [String: Any] = [
                                "id": "litertlm-\(UUID().uuidString.prefix(8))",
                                "object": "chat.completion.chunk",
                                "created": Int(Date().timeIntervalSince1970),
                                "model": modelId,
                                "choices": [[
                                    "index": 0,
                                    "delta": ["role": "assistant", "content": text],
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

        let reply = try await conversation.sendMessage(message)
        let json: [String: Any] = [
            "id": "litertlm-\(UUID().uuidString.prefix(8))",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": modelId,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": reply.toString],
                "finish_reason": "stop",
            ]],
        ]
        return .json(200, json)
    }

    public func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        let prompt = (body["prompt"] as? String) ?? ""
        let conversation = try await engine.createConversation()
        let reply = try await conversation.sendMessage(Message(prompt))
        let json: [String: Any] = [
            "id": "litertlm-\(UUID().uuidString.prefix(8))",
            "object": "text_completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": modelId,
            "choices": [[
                "text": reply.toString,
                "index": 0,
                "finish_reason": "stop",
            ]],
        ]
        return .json(200, json)
    }

    public func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        // LiteRT-LM is an LLM runtime, not an embedding provider. Same
        // posture as MLX — point callers at .llama or .coreml.
        return .error(501, "LiteRT-LM backend does not expose embeddings; use BackendKind.llama or .coreml for /v1/embeddings.")
    }

    public func handleModels(ctx: HandlerContext) async throws -> HandlerResponse {
        let json: [String: Any] = [
            "object": "list",
            "data": [[
                "id": modelId,
                "object": "model",
                "created": Int(Date().timeIntervalSince1970),
                "owned_by": "litertlm",
            ]],
        ]
        return .json(200, json)
    }

    /// Serialise OpenAI-style messages array into a Gemma chat-template
    /// prompt. Same shape LiteRT-LM Android core uses and matches the JS
    /// LiteRTLMBackend implementation in @dvai-bridge/core.
    ///
    /// ponytail: single-Gemma template — replace with a per-model
    /// dispatch if we ever ship non-Gemma models via LiteRT-LM.
    public static func flattenMessagesToPrompt(_ messages: [[String: Any]]) -> String {
        var parts: [String] = []
        for m in messages {
            let rawRole = (m["role"] as? String) ?? "user"
            let role: String
            switch rawRole {
            case "assistant": role = "model"
            case "system":    role = "user"     // LiteRT-LM web has no system role.
            default:          role = "user"
            }
            let content = (m["content"] as? String) ?? ""
            parts.append("<start_of_turn>\(role)\n\(content)\n<end_of_turn>")
        }
        parts.append("<start_of_turn>model\n")
        return parts.joined(separator: "\n")
    }
}
