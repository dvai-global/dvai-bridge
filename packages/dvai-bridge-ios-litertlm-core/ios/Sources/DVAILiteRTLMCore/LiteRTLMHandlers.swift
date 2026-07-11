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
                            let text = partial.text ?? ""
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
                "message": ["role": "assistant", "content": reply.text ?? ""],
                "finish_reason": "stop",
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
