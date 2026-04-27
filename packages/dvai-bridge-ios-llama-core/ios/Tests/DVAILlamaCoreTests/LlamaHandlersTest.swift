import XCTest
@testable import DVAILlamaCore
import DVAILlamaCoreObjC
import DVAISharedCore

/// Mock bridge so handler tests don't need a real GGUF model loaded.
/// Records the prompt that was passed in and returns canned values.
final class MockBridge: LlamaCppBridgeProtocol {
    var loaded: Bool = true
    var completionToReturn: String = "canned response"
    var multimodalCompletionToReturn: String = "canned multimodal response"
    var embeddingToReturn: [NSNumber] = [NSNumber(value: 0.1), NSNumber(value: 0.2), NSNumber(value: 0.3)]
    var receivedPrompt: String?
    var receivedMultimodalPrompt: String?
    var receivedMedia: [Data] = []
    var receivedEmbeddingTexts: [String] = []
    var completionShouldThrow: Bool = false
    var multimodalShouldThrow: Bool = false
    var embeddingShouldThrow: Bool = false
    // Phase 2A Pass 2: real mmproj surface.
    var mmprojLoaded: Bool = false
    var modelHasAudioEncoder: Bool = false
    var receivedMmprojPath: String?
    var loadMmprojShouldThrow: Bool = false
    // Chat template: identity-with-markers by default so tests can assert
    // marker count from the rendered string.
    var receivedChatTemplate: String?
    var receivedChatMessages: [[String: String]] = []
    var chatTemplateShouldThrow: Bool = false
    /// Closure that builds the rendered template from the messages. Default
    /// concatenates `<role>: <content>\n` for each message — preserves marker
    /// positions inside content fields so handler tests can verify marker count.
    var chatTemplateRenderer: ([[String: String]], Bool) -> String = { msgs, addAssistant in
        var s = ""
        for m in msgs {
            s += "\(m["role"] ?? "user"): \(m["content"] ?? "")\n"
        }
        if addAssistant { s += "assistant:" }
        return s
    }

    var isLoaded: Bool { loaded }
    var isMmprojLoaded: Bool { mmprojLoaded }

    func completePrompt(_ prompt: String, maxTokens: Int32, temperature: Float, topP: Float) throws -> String {
        receivedPrompt = prompt
        if completionShouldThrow {
            throw NSError(domain: "MockBridge", code: 99, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        return completionToReturn
    }

    func embedding(_ text: String) throws -> [NSNumber] {
        receivedEmbeddingTexts.append(text)
        if embeddingShouldThrow {
            throw NSError(domain: "MockBridge", code: 100, userInfo: [NSLocalizedDescriptionKey: "embed boom"])
        }
        return embeddingToReturn
    }

    func loadMmproj(atPath path: String) throws {
        receivedMmprojPath = path
        if loadMmprojShouldThrow {
            throw NSError(domain: "MockBridge", code: 101, userInfo: [NSLocalizedDescriptionKey: "mmproj boom"])
        }
        mmprojLoaded = true
    }

    func unloadMmproj() {
        mmprojLoaded = false
    }

    func hasAudioEncoder() -> Bool { modelHasAudioEncoder }

    func applyChatTemplate(
        _ templateOverride: String?,
        messages: [[String: String]],
        addAssistant: Bool
    ) throws -> String {
        receivedChatTemplate = templateOverride
        receivedChatMessages = messages
        if chatTemplateShouldThrow {
            throw NSError(domain: "MockBridge", code: 102, userInfo: [NSLocalizedDescriptionKey: "template boom"])
        }
        return chatTemplateRenderer(messages, addAssistant)
    }

    func completeMultimodalPrompt(
        _ prompt: String,
        media: [Data],
        maxTokens: Int32,
        temperature: Float,
        topP: Float
    ) throws -> String {
        receivedMultimodalPrompt = prompt
        receivedMedia = media
        if multimodalShouldThrow {
            throw NSError(domain: "MockBridge", code: 103, userInfo: [NSLocalizedDescriptionKey: "multimodal boom"])
        }
        return multimodalCompletionToReturn
    }
}

final class LlamaHandlersTest: XCTestCase {
    let ctx = HandlerContext(modelId: "test-model", backendName: "llama")

    private func makeHandlers(
        bridge: MockBridge = MockBridge(),
        mmprojLoaded: Bool = false,
        modelHasAudioEncoder: Bool = false,
        embeddingMode: Bool = false
    ) -> LlamaHandlers {
        LlamaHandlers(
            bridgeProtocol: bridge,
            modelId: "test-model",
            mmprojLoaded: mmprojLoaded,
            modelHasAudioEncoder: modelHasAudioEncoder,
            embeddingMode: embeddingMode
        )
    }

    // MARK: - Chat completion

    func testChatCompletionTextHappyPath() async throws {
        let bridge = MockBridge()
        bridge.completionToReturn = "Hello, world!"
        let handlers = makeHandlers(bridge: bridge)
        let body: [String: Any] = ["messages": [["role": "user", "content": "hi"]]]
        let resp = try await handlers.handleChatCompletion(body: body, ctx: ctx)
        guard case .json(let status, let bodyAny) = resp else {
            XCTFail("expected .json response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 200)
        let json = bodyAny as? [String: Any]
        XCTAssertEqual(json?["object"] as? String, "chat.completion")
        XCTAssertEqual(json?["model"] as? String, "test-model")
        let choices = json?["choices"] as? [[String: Any]]
        let msg = choices?.first?["message"] as? [String: Any]
        XCTAssertEqual(msg?["content"] as? String, "Hello, world!")
        XCTAssertEqual(msg?["role"] as? String, "assistant")
        XCTAssertEqual(choices?.first?["finish_reason"] as? String, "stop")
        // Phase 2A Pass 2: receivedPrompt is now the chat-template-rendered
        // string (the mock concatenates `<role>: <content>\n[assistant:]`).
        // Just assert it contains the original user content.
        XCTAssertTrue(bridge.receivedPrompt?.contains("hi") ?? false, "receivedPrompt: \(String(describing: bridge.receivedPrompt))")
    }

    /// Parse a single SSE frame into a `[String: Any]` payload. Returns
    /// `["__done__": true]` for `data: [DONE]`, `[:]` if the frame isn't a
    /// `data:` line, or the parsed JSON object otherwise.
    private func decodeFrame(_ frame: String) -> [String: Any] {
        let trimmed = frame.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data: ") else { return [:] }
        let payload = String(trimmed.dropFirst("data: ".count))
        if payload == "[DONE]" { return ["__done__": true] }
        guard let data = payload.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return parsed
    }

    func testChatCompletionStreamingTextEmitsRoleContentFinishDone() async throws {
        let bridge = MockBridge()
        bridge.completionToReturn = "stream-canned"
        let handlers = makeHandlers(bridge: bridge)
        let body: [String: Any] = [
            "messages": [["role": "user", "content": "hi"]],
            "stream": true,
        ]
        let resp = try await handlers.handleChatCompletion(body: body, ctx: ctx)
        guard case .sse(let stream) = resp else {
            XCTFail("expected .sse response, got \(resp)")
            return
        }
        var collected: [String] = []
        for await chunk in stream {
            collected.append(chunk)
        }
        XCTAssertEqual(collected.count, 4, "expected 4 SSE frames: role / content / finish / [DONE]")

        // Frame 0: role delta
        let roleFrame = decodeFrame(collected[0])
        let roleChoices = roleFrame["choices"] as? [[String: Any]]
        let roleDelta = roleChoices?.first?["delta"] as? [String: Any]
        XCTAssertEqual(roleDelta?["role"] as? String, "assistant")

        // Frame 1: content delta with the canned string
        let contentFrame = decodeFrame(collected[1])
        let contentChoices = contentFrame["choices"] as? [[String: Any]]
        let contentDelta = contentChoices?.first?["delta"] as? [String: Any]
        XCTAssertEqual(contentDelta?["content"] as? String, "stream-canned")

        // Frame 2: finish chunk
        let finishFrame = decodeFrame(collected[2])
        let finishChoices = finishFrame["choices"] as? [[String: Any]]
        XCTAssertEqual(finishChoices?.first?["finish_reason"] as? String, "stop")

        // Frame 3: [DONE]
        XCTAssertEqual(collected[3], "data: [DONE]\n\n")
        XCTAssertEqual(decodeFrame(collected[3])["__done__"] as? Bool, true)
    }

    func testChatCompletionBridgeThrowsReturns500() async throws {
        let bridge = MockBridge()
        bridge.completionShouldThrow = true
        let handlers = makeHandlers(bridge: bridge)
        let body: [String: Any] = ["messages": [["role": "user", "content": "hi"]]]
        let resp = try await handlers.handleChatCompletion(body: body, ctx: ctx)
        guard case .error(let status, _) = resp else {
            XCTFail("expected .error response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 500)
    }

    func testEmbeddingsBridgeThrowsReturns500() async throws {
        let bridge = MockBridge()
        bridge.embeddingShouldThrow = true
        let handlers = makeHandlers(bridge: bridge, embeddingMode: true)
        let resp = try await handlers.handleEmbeddings(body: ["input": "hi"], ctx: ctx)
        guard case .error(let status, _) = resp else {
            XCTFail("expected .error response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 500)
    }

    func testChatCompletionImageWithoutMmprojReturns400() async throws {
        let handlers = makeHandlers(mmprojLoaded: false)
        let body: [String: Any] = [
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,iVBOR"]] as [String: Any],
                ],
            ] as [String: Any]],
        ]
        let resp = try await handlers.handleChatCompletion(body: body, ctx: ctx)
        guard case .error(let status, let message) = resp else {
            XCTFail("expected .error response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 400)
        XCTAssertTrue(message.contains("no mmproj was loaded"), "message: \(message)")
        XCTAssertTrue(message.contains("nativeMmprojPath"), "message: \(message)")
    }

    func testChatCompletionAudioWithoutEncoderReturns400() async throws {
        let handlers = makeHandlers(modelHasAudioEncoder: false)
        let body: [String: Any] = [
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "input_audio", "input_audio": ["data": "AAAA", "format": "pcm16"]] as [String: Any],
                ],
            ] as [String: Any]],
        ]
        let resp = try await handlers.handleChatCompletion(body: body, ctx: ctx)
        guard case .error(let status, let message) = resp else {
            XCTFail("expected .error response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 400)
        XCTAssertTrue(message.contains("native audio encoder"), "message: \(message)")
    }

    // MARK: - Multimodal happy paths (Phase 2A Pass 2)

    /// Image happy path: mmprojLoaded=true, body contains a tiny PNG data URL.
    /// The mock bridge records the call to completeMultimodalPrompt with
    /// media.count == 1; the rendered prompt has exactly one <__media__>
    /// marker; assert the OpenAI chat.completion shape on response.
    func testChatVisionHappyPath() async throws {
        let bridge = MockBridge()
        bridge.multimodalCompletionToReturn = "I see a 1x1 transparent pixel."
        let handlers = makeHandlers(bridge: bridge, mmprojLoaded: true)
        let body: [String: Any] = [
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "What's in this image?"],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="]] as [String: Any],
                ],
            ] as [String: Any]],
        ]
        let resp = try await handlers.handleChatCompletion(body: body, ctx: ctx)
        guard case .json(let status, let bodyAny) = resp else {
            XCTFail("expected .json response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(bridge.receivedMedia.count, 1)
        // The chat-template renderer in the mock concatenates `<role>: <content>\n`,
        // so the rendered prompt should contain exactly one <__media__> marker.
        let prompt = bridge.receivedMultimodalPrompt ?? ""
        let markerCount = prompt.components(separatedBy: MTMD_MEDIA_MARKER).count - 1
        XCTAssertEqual(markerCount, 1, "expected exactly one <__media__> marker, got prompt: \(prompt)")
        let json = bodyAny as? [String: Any]
        XCTAssertEqual(json?["object"] as? String, "chat.completion")
        let choices = json?["choices"] as? [[String: Any]]
        let msg = choices?.first?["message"] as? [String: Any]
        XCTAssertEqual(msg?["content"] as? String, "I see a 1x1 transparent pixel.")
    }

    /// Audio happy path: modelHasAudioEncoder=true, body contains a tiny
    /// pcm16 base64. Bridge records the call to completeMultimodalPrompt;
    /// media.count == 1.
    func testChatAudioHappyPath() async throws {
        let bridge = MockBridge()
        bridge.multimodalCompletionToReturn = "hello world"
        let handlers = makeHandlers(bridge: bridge, modelHasAudioEncoder: true)
        // 8 zero-bytes — the pcm16 path is pass-through (no decode), so the
        // translator does not need to call AudioDecoder for this format.
        let pcm = Data(repeating: 0, count: 32)
        let body: [String: Any] = [
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "Transcribe:"],
                    ["type": "input_audio", "input_audio": ["data": pcm.base64EncodedString(), "format": "pcm16"]] as [String: Any],
                ],
            ] as [String: Any]],
        ]
        let resp = try await handlers.handleChatCompletion(body: body, ctx: ctx)
        guard case .json(let status, _) = resp else {
            XCTFail("expected .json response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(bridge.receivedMedia.count, 1)
        XCTAssertEqual(bridge.receivedMedia[0], pcm)
        let prompt = bridge.receivedMultimodalPrompt ?? ""
        let markerCount = prompt.components(separatedBy: MTMD_MEDIA_MARKER).count - 1
        XCTAssertEqual(markerCount, 1)
    }

    /// Interleaved [text, image, text, audio, text]: media list is
    /// [imageBytes, audioBytes] in declaration order; rendered prompt has
    /// exactly two <__media__> markers in the right positions.
    func testChatInterleavedImageAudio() async throws {
        let bridge = MockBridge()
        let handlers = makeHandlers(
            bridge: bridge,
            mmprojLoaded: true,
            modelHasAudioEncoder: true
        )
        let pcm = Data(repeating: 0xAB, count: 16)
        let body: [String: Any] = [
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "alpha"],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,iVBORw0KGgo="]] as [String: Any],
                    ["type": "text", "text": "beta"],
                    ["type": "input_audio", "input_audio": ["data": pcm.base64EncodedString(), "format": "pcm16"]] as [String: Any],
                    ["type": "text", "text": "gamma"],
                ],
            ] as [String: Any]],
        ]
        let resp = try await handlers.handleChatCompletion(body: body, ctx: ctx)
        guard case .json(let status, _) = resp else {
            XCTFail("expected .json response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(bridge.receivedMedia.count, 2)
        // Audio bytes should match (image bytes are the data-URL-decoded PNG
        // header — we don't assert exact bytes, just that the audio is at
        // index 1 after the image).
        XCTAssertEqual(bridge.receivedMedia[1], pcm)
        let prompt = bridge.receivedMultimodalPrompt ?? ""
        let markerCount = prompt.components(separatedBy: MTMD_MEDIA_MARKER).count - 1
        XCTAssertEqual(markerCount, 2, "expected exactly two markers, got prompt: \(prompt)")
    }

    func testChatCompletionMissingMessagesReturns400() async throws {
        let handlers = makeHandlers()
        let resp = try await handlers.handleChatCompletion(body: [:], ctx: ctx)
        guard case .error(let status, let message) = resp else {
            XCTFail("expected .error response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 400)
        XCTAssertTrue(message.contains("messages"), "message: \(message)")
    }

    // MARK: - Legacy /v1/completions

    func testCompletionLegacyConvertsToTextCompletion() async throws {
        let bridge = MockBridge()
        bridge.completionToReturn = "canned-text"
        let handlers = makeHandlers(bridge: bridge)
        let resp = try await handlers.handleCompletion(body: ["prompt": "say hi"], ctx: ctx)
        guard case .json(let status, let bodyAny) = resp else {
            XCTFail("expected .json response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 200)
        let json = bodyAny as? [String: Any]
        XCTAssertEqual(json?["object"] as? String, "text_completion")
        let choices = json?["choices"] as? [[String: Any]]
        XCTAssertEqual(choices?.first?["text"] as? String, "canned-text")
        XCTAssertEqual(choices?.first?["finish_reason"] as? String, "stop")
        // logprobs is NSNull — present in the dict.
        XCTAssertNotNil(choices?.first?["logprobs"])
        // ID was rewritten chatcmpl- → cmpl-
        let idStr = json?["id"] as? String ?? ""
        XCTAssertTrue(idStr.hasPrefix("cmpl-"), "id should start with cmpl-: \(idStr)")
        // Round-tripped prompt -- now wrapped by the chat-template renderer.
        XCTAssertTrue(bridge.receivedPrompt?.contains("say hi") ?? false, "receivedPrompt: \(String(describing: bridge.receivedPrompt))")
    }

    func testCompletionLegacyArrayPromptJoinedWithNewline() async throws {
        let bridge = MockBridge()
        let handlers = makeHandlers(bridge: bridge)
        let resp = try await handlers.handleCompletion(body: ["prompt": ["alpha", "beta"]], ctx: ctx)
        guard case .json = resp else {
            XCTFail("expected .json response, got \(resp)")
            return
        }
        XCTAssertTrue(bridge.receivedPrompt?.contains("alpha\nbeta") ?? false, "receivedPrompt: \(String(describing: bridge.receivedPrompt))")
    }

    // MARK: - Embeddings

    func testEmbeddingsRejectedWhenNotEmbeddingMode() async throws {
        let handlers = makeHandlers(embeddingMode: false)
        let resp = try await handlers.handleEmbeddings(body: ["input": "hello"], ctx: ctx)
        guard case .error(let status, let message) = resp else {
            XCTFail("expected .error response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 400)
        XCTAssertTrue(message.contains("nativeEmbeddingMode"), "message: \(message)")
    }

    func testEmbeddingsHappyPathSingleString() async throws {
        let bridge = MockBridge()
        bridge.embeddingToReturn = [NSNumber(value: 0.5), NSNumber(value: -0.25), NSNumber(value: 1.0)]
        let handlers = makeHandlers(bridge: bridge, embeddingMode: true)
        let resp = try await handlers.handleEmbeddings(body: ["input": "hello"], ctx: ctx)
        guard case .json(let status, let bodyAny) = resp else {
            XCTFail("expected .json response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 200)
        let json = bodyAny as? [String: Any]
        XCTAssertEqual(json?["object"] as? String, "list")
        XCTAssertEqual(json?["model"] as? String, "test-model")
        let data = json?["data"] as? [[String: Any]]
        XCTAssertEqual(data?.count, 1)
        XCTAssertEqual(data?.first?["object"] as? String, "embedding")
        XCTAssertEqual(data?.first?["index"] as? Int, 0)
        let vec = data?.first?["embedding"] as? [Double]
        XCTAssertEqual(vec?.count, 3)
        guard let unwrapped = vec, unwrapped.count == 3 else {
            XCTFail("expected 3-element vec; got \(String(describing: vec))")
            return
        }
        XCTAssertEqual(unwrapped[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(unwrapped[1], -0.25, accuracy: 1e-6)
        XCTAssertEqual(unwrapped[2], 1.0, accuracy: 1e-6)
        XCTAssertEqual(bridge.receivedEmbeddingTexts, ["hello"])
    }

    func testEmbeddingsArrayInputProducesMultipleEntries() async throws {
        let bridge = MockBridge()
        let handlers = makeHandlers(bridge: bridge, embeddingMode: true)
        let resp = try await handlers.handleEmbeddings(
            body: ["input": ["alpha", "beta", "gamma"]],
            ctx: ctx
        )
        guard case .json(let status, let bodyAny) = resp else {
            XCTFail("expected .json response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 200)
        let data = (bodyAny as? [String: Any])?["data"] as? [[String: Any]]
        XCTAssertEqual(data?.count, 3)
        XCTAssertEqual(data?[0]["index"] as? Int, 0)
        XCTAssertEqual(data?[1]["index"] as? Int, 1)
        XCTAssertEqual(data?[2]["index"] as? Int, 2)
        XCTAssertEqual(bridge.receivedEmbeddingTexts, ["alpha", "beta", "gamma"])
    }

    func testEmbeddingsMissingInputReturns400() async throws {
        let handlers = makeHandlers(embeddingMode: true)
        let resp = try await handlers.handleEmbeddings(body: [:], ctx: ctx)
        guard case .error(let status, _) = resp else {
            XCTFail("expected .error response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 400)
    }

    // MARK: - Models

    func testModelsReturnsSingleEntryListWithCtxModelId() async throws {
        let handlers = makeHandlers()
        let customCtx = HandlerContext(modelId: "/path/to/model.gguf", backendName: "llama")
        let resp = try await handlers.handleModels(ctx: customCtx)
        guard case .json(let status, let bodyAny) = resp else {
            XCTFail("expected .json response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 200)
        let json = bodyAny as? [String: Any]
        XCTAssertEqual(json?["object"] as? String, "list")
        let data = json?["data"] as? [[String: Any]]
        XCTAssertEqual(data?.count, 1)
        XCTAssertEqual(data?.first?["id"] as? String, "/path/to/model.gguf")
    }
}
