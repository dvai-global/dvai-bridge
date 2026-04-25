// Internal/FoundationHandlers.swift
//
// OpenAI-compatible handler set backed by Apple's `FoundationModels`
// framework (`LanguageModelSession`).
//
// Availability — DEVIATION FROM PLAN: the plan documented `iOS 18.1+`,
// but on the current Xcode 26.4 / iPhoneSimulator26.4 SDK, every public
// `LanguageModelSession` symbol carries `@available(iOS 26.0, *)`
// (likewise macOS 26 / macCatalyst 26 / visionOS 26). The Apple
// FoundationModels framework's runtime requirement was raised between
// the early plan draft and Xcode 26's release. We therefore guard the
// whole class with `@available(iOS 26.0, macOS 26.0, *)`. The package's
// SwiftPM `iOS("18.1")` floor stays — the framework is a strict
// availability annotation, not a hard link, so older iOS 18.1+ apps
// still build; they just cannot call into FoundationHandlers without
// their own `if #available(iOS 26, *)` check.
//
// Phase 1 scope (per spec §8.4 modality matrix): text only.
// - Image content parts → 400 (spec §8.5 wording).
// - Audio content parts → 400 (spec §8.5 wording).
// - /v1/embeddings → 400 (Apple FM has no public embedding API).
//
// Streaming: 4-frame SSE envelope (role / content* / finish / [DONE]),
// mirroring `LlamaHandlers`. Multiple content frames are emitted, one per
// partial response yielded by `LanguageModelSession.responseStream(to:)`.
// Telegraph 0.40 buffers the SSE body server-side so per-frame flushing
// is identical to single-frame to clients today.
//
// Concurrency: `LanguageModelSession` is a stateful conversation object;
// concurrent requests would interleave turns. All session-touching paths
// are serialized via `sessionLock`, same pattern as `LlamaHandlers`.
//
// Host-build guard: `#if canImport(FoundationModels)` keeps the file
// compilable on macOS hosts whose Xcode SDK predates FoundationModels.
// On those hosts the entire class compiles out and the test target
// guards itself the same way.

#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
public final class FoundationHandlers: DVAIHandlers, @unchecked Sendable {
    private let modelId: String
    private var session: LanguageModelSession?
    private let sessionLock = NSLock()

    public init(modelId: String = "apple-foundation-3b") {
        self.modelId = modelId
    }

    private func ensureSession() -> LanguageModelSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let s = session { return s }
        let s = LanguageModelSession()
        session = s
        return s
    }

    // MARK: - /v1/chat/completions

    public func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        // Reject image / audio content parts up-front (spec §8.5 wording).
        if let messages = body["messages"] as? [[String: Any]] {
            for msg in messages {
                if let parts = msg["content"] as? [[String: Any]] {
                    for part in parts {
                        if let type = part["type"] as? String {
                            if type == "image_url" {
                                return .error(400, "Image input not supported by Apple Foundation Models in this version.")
                            }
                            if type == "input_audio" {
                                return .error(400, "Audio input not supported by Apple Foundation Models in this version.")
                            }
                        }
                    }
                }
            }
        }

        let messages = body["messages"] as? [[String: Any]] ?? []
        let prompt = openAIMessagesToPrompt(messages)
        let session = ensureSession()
        let id = "chatcmpl-fm-\(UUID().uuidString.prefix(20).lowercased())"
        let created = Int(Date().timeIntervalSince1970)

        if (body["stream"] as? Bool) == true {
            let modelId = self.modelId
            let stream = AsyncStream<String> { continuation in
                Task {
                    do {
                        // Frame 1: role delta
                        let roleChunk: [String: Any] = [
                            "id": id,
                            "object": "chat.completion.chunk",
                            "created": created,
                            "model": modelId,
                            "choices": [[
                                "index": 0,
                                "delta": ["role": "assistant"],
                            ] as [String: Any]],
                        ]
                        if let s = Self.serialize(roleChunk) {
                            continuation.yield("data: \(s)\n\n")
                        }

                        // Frames 2..N: content deltas, one per partial response.
                        // DEVIATION FROM PLAN: plan used `responseStream(to:)` —
                        // actual API is `streamResponse(to:)` (returns
                        // `ResponseStream`, conforms to `AsyncSequence`,
                        // partials expose `.content`).
                        for try await partial in session.streamResponse(to: prompt) {
                            let chunk: [String: Any] = [
                                "id": id,
                                "object": "chat.completion.chunk",
                                "created": created,
                                "model": modelId,
                                "choices": [[
                                    "index": 0,
                                    "delta": ["content": partial.content],
                                ] as [String: Any]],
                            ]
                            if let s = Self.serialize(chunk) {
                                continuation.yield("data: \(s)\n\n")
                            }
                        }

                        // Frame N+1: finish
                        let finishChunk: [String: Any] = [
                            "id": id,
                            "object": "chat.completion.chunk",
                            "created": created,
                            "model": modelId,
                            "choices": [[
                                "index": 0,
                                "delta": [:] as [String: Any],
                                "finish_reason": "stop",
                            ] as [String: Any]],
                        ]
                        if let s = Self.serialize(finishChunk) {
                            continuation.yield("data: \(s)\n\n")
                        }

                        continuation.yield("data: [DONE]\n\n")
                    } catch {
                        // Stream errored mid-flight — close cleanly. Clients see
                        // whatever frames already arrived; no error frame is
                        // emitted because OpenAI's SSE protocol doesn't define one.
                    }
                    continuation.finish()
                }
            }
            return .sse(stream)
        }

        // Non-streaming
        do {
            let response = try await session.respond(to: prompt)
            let json: [String: Any] = [
                "id": id,
                "object": "chat.completion",
                "created": created,
                "model": modelId,
                "choices": [[
                    "index": 0,
                    "message": ["role": "assistant", "content": response.content],
                    "finish_reason": "stop",
                ] as [String: Any]],
                "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0],
            ]
            return .json(200, json)
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    // MARK: - /v1/completions (legacy)

    public func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        let promptField = body["prompt"]
        let prompt: String
        if let s = promptField as? String {
            prompt = s
        } else if let arr = promptField as? [String] {
            prompt = arr.joined(separator: "\n")
        } else {
            prompt = ""
        }

        var chatBody = body
        chatBody["messages"] = [["role": "user", "content": prompt]]
        chatBody.removeValue(forKey: "prompt")

        let chatResp = try await handleChatCompletion(body: chatBody, ctx: ctx)
        switch chatResp {
        case .json(let status, let chatBodyAny):
            guard status == 200, let chat = chatBodyAny as? [String: Any] else {
                return chatResp
            }
            return .json(200, chatToLegacyCompletion(chat))
        case .sse(let chatStream):
            let legacyStream = AsyncStream<String> { continuation in
                Task {
                    for await chunk in chatStream {
                        continuation.yield(self.adaptChunkToLegacy(chunk))
                    }
                    continuation.finish()
                }
            }
            return .sse(legacyStream)
        case .error:
            return chatResp
        }
    }

    // MARK: - /v1/embeddings

    public func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .error(400, "Embeddings not supported on Apple Foundation Models in this version.")
    }

    // MARK: - /v1/models

    public func handleModels(ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(200, [
            "object": "list",
            "data": [["id": modelId, "object": "model", "owned_by": "apple"] as [String: Any]],
        ])
    }

    // MARK: - Helpers

    private func openAIMessagesToPrompt(_ messages: [[String: Any]]) -> String {
        var lines: [String] = []
        for msg in messages {
            let role = (msg["role"] as? String) ?? "user"
            if let text = msg["content"] as? String {
                lines.append("\(role): \(text)")
            } else if let parts = msg["content"] as? [[String: Any]] {
                for part in parts {
                    if (part["type"] as? String) == "text" {
                        lines.append("\(role): \(part["text"] as? String ?? "")")
                    }
                    // image_url / input_audio rejected before we get here
                    // (handleChatCompletion early-returns 400).
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func serialize(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    /// Convert a chat.completion JSON body to the legacy text_completion shape.
    /// Mirrors the same helper in `LlamaHandlers` and `packages/dvai-bridge-core`.
    private func chatToLegacyCompletion(_ chat: [String: Any]) -> [String: Any] {
        var legacy: [String: Any] = [:]
        let chatId = chat["id"] as? String ?? ""
        legacy["id"] = chatId.isEmpty
            ? "cmpl-\(Int(Date().timeIntervalSince1970))"
            : chatId.replacingOccurrences(of: "chatcmpl-", with: "cmpl-")
        legacy["object"] = "text_completion"
        legacy["created"] = chat["created"] ?? Int(Date().timeIntervalSince1970)
        legacy["model"] = chat["model"] ?? modelId
        let choices = (chat["choices"] as? [[String: Any]]) ?? []
        legacy["choices"] = choices.map { c -> [String: Any] in
            let msg = c["message"] as? [String: Any]
            return [
                "text": (msg?["content"] as? String) ?? "",
                "index": c["index"] ?? 0,
                "finish_reason": c["finish_reason"] ?? "stop",
                "logprobs": NSNull(),
            ] as [String: Any]
        }
        legacy["usage"] = chat["usage"] ?? ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]
        return legacy
    }

    /// Adapt one SSE frame from chat.completion.chunk → text_completion.chunk.
    /// `[DONE]` is forwarded unchanged. Frames that don't parse fall through.
    private func adaptChunkToLegacy(_ chunk: String) -> String {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return chunk }
        let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return "data: [DONE]\n\n" }
        guard let data = payload.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return chunk
        }
        let chatId = parsed["id"] as? String ?? ""
        let id = chatId.replacingOccurrences(of: "chatcmpl-", with: "cmpl-")
        var legacyChoices: [[String: Any]] = []
        for c in (parsed["choices"] as? [[String: Any]]) ?? [] {
            let delta = c["delta"] as? [String: Any]
            legacyChoices.append([
                "text": (delta?["content"] as? String) ?? "",
                "index": c["index"] ?? 0,
                "finish_reason": c["finish_reason"] ?? NSNull(),
                "logprobs": NSNull(),
            ] as [String: Any])
        }
        let legacy: [String: Any] = [
            "id": id,
            "object": "text_completion.chunk",
            "created": parsed["created"] ?? Int(Date().timeIntervalSince1970),
            "model": parsed["model"] ?? modelId,
            "choices": legacyChoices,
        ]
        if let s = Self.serialize(legacy) { return "data: \(s)\n\n" }
        return chunk
    }
}
#endif
