// Internal/LlamaHandlers.swift
import Foundation
import DVAILlamaCoreObjC

/// OpenAI-compatible handler set for the llama backend. Wires
/// `ContentPartsTranslator` → `bridge.completePrompt` → OpenAI response shape
/// per spec §6 + §8.
///
/// Phase 1 scope (all `false` until Phase 2 lands the corresponding loaders):
/// - `mmprojLoaded`: true once a multimodal projector is loaded; gates image parts.
/// - `modelHasAudioEncoder`: true once a model with native audio is loaded; gates audio parts.
/// - `embeddingMode`: mirrored from the start opts; gates POST /v1/embeddings.
///
/// Streaming: SSE chunks are emitted in 4 frames (role / content / finish /
/// `[DONE]`). Telegraph 0.40 buffers the whole SSE body server-side anyway, so
/// 4-chunk vs 1-chunk is identical to the client. Real per-token streaming
/// lands when Telegraph (or its replacement) supports chunked-encoding flush.
///
/// Note: this 4-frame shape with a separate empty-delta finish frame matches
/// `FoundationHandlers` (iOS, capacitor-foundation) but intentionally differs
/// from `MediaPipeHandlers` (Android, capacitor-mediapipe), which folds
/// `finish_reason: "stop"` onto its final content delta and emits a variable
/// number of frames. See `MediaPipeHandlers`' "Streaming envelope parity"
/// KDoc section, and `docs/development/handler-parity.md`, for the full
/// comparison.
///
/// All bridge-touching paths are serialized via `bridgeLock` because
/// llama.cpp's `llama_context` is not thread-safe; concurrent requests
/// would corrupt the shared KV cache.
public final class LlamaHandlers: DVAIHandlers, @unchecked Sendable {
    private let bridge: LlamaCppBridgeProtocol
    private let bridgeLock = NSLock()
    private let modelId: String
    private let mmprojLoaded: Bool
    private let modelHasAudioEncoder: Bool
    private let embeddingMode: Bool
    private let chatTemplate: String?
    private let translator: ContentPartsTranslator

    /// Public initializer used by `PluginState`. Wraps a concrete
    /// `LlamaCppBridge` (the protocol existential) so tests can swap in fakes.
    public convenience init(
        bridge: LlamaCppBridge,
        modelId: String,
        mmprojLoaded: Bool = false,
        modelHasAudioEncoder: Bool = false,
        embeddingMode: Bool = false,
        chatTemplate: String? = nil
    ) {
        self.init(
            bridgeProtocol: bridge,
            modelId: modelId,
            mmprojLoaded: mmprojLoaded,
            modelHasAudioEncoder: modelHasAudioEncoder,
            embeddingMode: embeddingMode,
            chatTemplate: chatTemplate
        )
    }

    /// Internal initializer accepting the protocol existential — used by
    /// tests that inject a mock bridge. The public init forwards here.
    init(
        bridgeProtocol: LlamaCppBridgeProtocol,
        modelId: String,
        mmprojLoaded: Bool = false,
        modelHasAudioEncoder: Bool = false,
        embeddingMode: Bool = false,
        chatTemplate: String? = nil,
        translator: ContentPartsTranslator? = nil
    ) {
        self.bridge = bridgeProtocol
        self.modelId = modelId
        self.mmprojLoaded = mmprojLoaded
        self.modelHasAudioEncoder = modelHasAudioEncoder
        self.embeddingMode = embeddingMode
        self.chatTemplate = chatTemplate
        self.translator = translator ?? ContentPartsTranslator(
            mmprojLoaded: mmprojLoaded,
            modelHasAudioEncoder: modelHasAudioEncoder
        )
    }

    // MARK: - /v1/chat/completions

    public func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        guard let messages = body["messages"] as? [[String: Any]] else {
            return .error(400, "Missing 'messages' field")
        }

        let promptInput: LlamaPromptInput
        do {
            promptInput = try await translator.translate(messages: messages)
        } catch let e as TranslatorError {
            return .error(translatorErrorToStatus(e), translatorErrorMessage(e))
        }

        // TODO(strict-mode): currently silently defaults if max_tokens/temperature/top_p
        // arrive as strings instead of numbers; OpenAI rejects this with 400.
        let maxTokens = body["max_tokens"] as? Int ?? 256
        let temperature = body["temperature"] as? Double ?? 1.0
        let topP = body["top_p"] as? Double ?? 1.0
        let stream = body["stream"] as? Bool ?? false

        // Render the chat template. The bridge falls back to the model's
        // bundled tokenizer.chat_template when our override is nil/empty.
        // Marker positions inside content fields are preserved by the
        // translator, so the rendered prompt has N <__media__> markers
        // matching media.count in declaration order.
        let chatPrompt: String
        do {
            chatPrompt = try runOnBridge {
                try bridge.applyChatTemplate(
                    chatTemplate,
                    messages: promptInput.messagesWithMarkers.map { ["role": $0.role, "content": $0.content] },
                    addAssistant: true
                )
            }
        } catch {
            return .error(500, "chat template apply failed: \(error.localizedDescription)")
        }

        let completion: String
        do {
            if promptInput.media.isEmpty {
                completion = try runOnBridge {
                    try bridge.completePrompt(
                        chatPrompt,
                        maxTokens: Int32(maxTokens),
                        temperature: Float(temperature),
                        topP: Float(topP)
                    )
                }
            } else {
                completion = try runOnBridge {
                    try bridge.completeMultimodalPrompt(
                        chatPrompt,
                        media: promptInput.media,
                        maxTokens: Int32(maxTokens),
                        temperature: Float(temperature),
                        topP: Float(topP)
                    )
                }
            }
        } catch {
            return .error(500, error.localizedDescription)
        }

        let id = "chatcmpl-\(UUID().uuidString.prefix(24).lowercased())"
        let created = Int(Date().timeIntervalSince1970)

        if stream {
            // 4-chunk SSE: role delta, content delta with full body, finish, [DONE].
            let chunks = buildChatStreamChunks(
                id: id,
                created: created,
                completion: completion
            )
            let asyncStream = AsyncStream<String> { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
            return .sse(asyncStream)
        }

        let response: [String: Any] = [
            "id": id,
            "object": "chat.completion",
            "created": created,
            "model": modelId,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": completion],
                "finish_reason": "stop",
            ] as [String: Any]],
            "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0],
        ]
        return .json(200, response)
    }

    // MARK: - /v1/completions (legacy)

    public func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        let promptField = body["prompt"]
        let prompt: String
        if let s = promptField as? String {
            prompt = s
        } else if let arr = promptField as? [String] {
            prompt = arr.joined(separator: "\n")
        } else if promptField == nil {
            prompt = ""
        } else {
            return .error(400, "'prompt' must be a string or array of strings")
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
            let model = (body["model"] as? String) ?? modelId
            let legacyStream = AsyncStream<String> { continuation in
                Task {
                    for await chunk in chatStream {
                        continuation.yield(adaptChunkToLegacy(chunk, model: model))
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
        if !embeddingMode {
            return .error(400, "Embeddings require nativeEmbeddingMode: true at start time.")
        }
        let inputAny = body["input"]
        let inputs: [String]
        if let s = inputAny as? String {
            inputs = [s]
        } else if let arr = inputAny as? [String] {
            inputs = arr
        } else {
            return .error(400, "Missing or malformed 'input' field")
        }

        var data: [[String: Any]] = []
        for (i, text) in inputs.enumerated() {
            do {
                let vec = try runOnBridge { try bridge.embedding(text) }
                let embedding = vec.map { $0.doubleValue }
                data.append(["object": "embedding", "embedding": embedding, "index": i])
            } catch {
                return .error(500, error.localizedDescription)
            }
        }
        let response: [String: Any] = [
            "object": "list",
            "data": data,
            "model": modelId,
            "usage": ["prompt_tokens": 0, "total_tokens": 0],
        ]
        return .json(200, response)
    }

    // MARK: - /v1/models

    public func handleModels(ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(200, [
            "object": "list",
            "data": [["id": ctx.modelId, "object": "model", "owned_by": "dvai-bridge"] as [String: Any]],
        ])
    }

    // MARK: - Helpers

    private func translatorErrorToStatus(_ e: TranslatorError) -> Int {
        switch e {
        case .imageFetchFailed: return 502
        default: return 400
        }
    }

    private func translatorErrorMessage(_ e: TranslatorError) -> String {
        switch e {
        case .noMmprojForImage:
            return "Request includes an image but no mmproj was loaded. Set nativeMmprojPath when starting."
        case .audioWithoutAudioEncoder:
            return "Loaded model has no native audio encoder. Use a multimodal model like Gemma 4 or Phi-4 Multimodal."
        case .unsupportedAudioFormat(let fmt, let supported):
            return "Unsupported audio format: \(fmt). Supported on this platform: \(supported.joined(separator: ", "))."
        case .audioDecodeFailed(let reason):
            return "Audio decode failed: \(reason)"
        case .imageFetchFailed(let reason):
            return "Failed to fetch image: \(reason)"
        case .malformedRequest(let reason):
            return reason
        }
    }

    // Server-side buffering: Telegraph 0.40 does not stream chunks incrementally;
    // the entire AsyncStream content is gathered before the response is flushed.
    // 4-chunk vs single-chunk emission is identical to clients.
    /// Build the 4 SSE frames for a streaming chat.completion response.
    /// Each entry is the full `data: <json>\n\n` (or `data: [DONE]\n\n`)
    /// frame. Returned in protocol order: role, content, finish, DONE.
    private func buildChatStreamChunks(id: String, created: Int, completion: String) -> [String] {
        var out: [String] = []
        let role: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": modelId,
            "choices": [[
                "index": 0,
                "delta": ["role": "assistant"],
            ] as [String: Any]],
        ]
        if let s = serialize(role) { out.append("data: \(s)\n\n") }

        let content: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": modelId,
            "choices": [[
                "index": 0,
                "delta": ["content": completion],
            ] as [String: Any]],
        ]
        if let s = serialize(content) { out.append("data: \(s)\n\n") }

        let finish: [String: Any] = [
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
        if let s = serialize(finish) { out.append("data: \(s)\n\n") }

        out.append("data: [DONE]\n\n")
        return out
    }

    private func serialize(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    /// Convert a chat.completion JSON body to the legacy text_completion shape.
    /// Mirrors `chatToLegacyCompletion()` in `packages/dvai-bridge-core`.
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

    /// Adapt a single SSE frame from chat.completion.chunk → text_completion.chunk.
    /// `[DONE]` is forwarded unchanged. Frames that don't parse fall through.
    private func adaptChunkToLegacy(_ chunk: String, model: String) -> String {
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
            "model": parsed["model"] ?? model,
            "choices": legacyChoices,
        ]
        if let s = serialize(legacy) { return "data: \(s)\n\n" }
        return chunk
    }
}

private extension LlamaHandlers {
    /// Serialize all bridge-touching paths via `bridgeLock` so concurrent
    /// requests can't corrupt the shared `llama_context` KV cache.
    func runOnBridge<T>(_ block: () throws -> T) throws -> T {
        bridgeLock.lock()
        defer { bridgeLock.unlock() }
        return try block()
    }
}
