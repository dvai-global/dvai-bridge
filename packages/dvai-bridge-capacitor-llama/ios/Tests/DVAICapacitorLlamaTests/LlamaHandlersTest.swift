import XCTest
@testable import DVAICapacitorLlama
import DVAICapacitorLlamaObjC

/// Mock bridge so handler tests don't need a real GGUF model loaded.
/// Records the prompt that was passed in and returns canned values.
final class MockBridge: LlamaCppBridgeProtocol {
    var loaded: Bool = true
    var completionToReturn: String = "canned response"
    var embeddingToReturn: [NSNumber] = [NSNumber(value: 0.1), NSNumber(value: 0.2), NSNumber(value: 0.3)]
    var receivedPrompt: String?
    var receivedEmbeddingTexts: [String] = []
    var completionShouldThrow: Bool = false
    var embeddingShouldThrow: Bool = false

    var isLoaded: Bool { loaded }

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
        XCTAssertEqual(bridge.receivedPrompt, "hi")
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
        XCTAssertTrue(collected[0].contains("\"role\":\"assistant\""), "frame 0 should be role delta: \(collected[0])")
        // Frame 1: content delta with the canned string
        XCTAssertTrue(collected[1].contains("stream-canned"), "frame 1 should contain content: \(collected[1])")
        // Frame 2: finish chunk
        XCTAssertTrue(collected[2].contains("\"finish_reason\":\"stop\""), "frame 2 should have finish_reason: \(collected[2])")
        // Frame 3: [DONE]
        XCTAssertEqual(collected[3], "data: [DONE]\n\n")
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
        // Round-tripped prompt
        XCTAssertEqual(bridge.receivedPrompt, "say hi")
    }

    func testCompletionLegacyArrayPromptJoinedWithNewline() async throws {
        let bridge = MockBridge()
        let handlers = makeHandlers(bridge: bridge)
        let resp = try await handlers.handleCompletion(body: ["prompt": ["alpha", "beta"]], ctx: ctx)
        guard case .json = resp else {
            XCTFail("expected .json response, got \(resp)")
            return
        }
        XCTAssertEqual(bridge.receivedPrompt, "alpha\nbeta")
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
        XCTAssertEqual(vec?[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(vec?[1], -0.25, accuracy: 1e-9)
        XCTAssertEqual(vec?[2], 1.0, accuracy: 1e-9)
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
