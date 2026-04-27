// Tests/DVAICapacitorFoundationTests/FoundationHandlersTest.swift
//
// Unit tests for the `FoundationHandlers` paths that don't require a real
// `LanguageModelSession`:
//   1. handleEmbeddings → 400 with spec §8.5 wording.
//   2. handleModels → 200 with the canned single-entry list.
//   3. handleChatCompletion (image content part) → 400 with spec §8.5 wording.
//   4. handleChatCompletion (audio content part) → 400 with spec §8.5 wording.
//   5. handleChatCompletion (missing 'messages') → 400 short-circuit.
//   6. handleChatCompletion (empty 'messages' array) → 400 short-circuit.
//
// The chat happy path goes through `LanguageModelSession` and is verified
// on a real iOS device via the instrumented / manual tier (per Task 40
// plan note: "handleChatCompletion happy path requires real device — skip
// in unit tests").
//
// The whole class is guarded by `#if canImport(FoundationModels)`. On a
// macOS host without FoundationModels (older Xcode), the tests compile
// out and the smoke test still runs.

import XCTest
@testable import DVAIFoundationCore
import DVAISharedCore

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
final class FoundationHandlersTest: XCTestCase {

    private func ctx() -> HandlerContext {
        HandlerContext(modelId: "apple-foundation-3b", backendName: "foundation")
    }

    func testEmbeddingsReturnsSpecConformant400() async throws {
        let handlers = FoundationHandlers()
        let response = try await handlers.handleEmbeddings(
            body: ["input": "hi"],
            ctx: ctx()
        )
        if case .error(let status, let message) = response {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(
                message.contains("Embeddings not supported on Apple Foundation Models"),
                "Expected spec §8.5 wording, got: \(message)"
            )
        } else {
            XCTFail("Expected .error(400, ...), got \(response)")
        }
    }

    func testModelsReturnsAppleFoundationEntry() async throws {
        let handlers = FoundationHandlers()
        let response = try await handlers.handleModels(ctx: ctx())
        guard case .json(let status, let body) = response,
              let dict = body as? [String: Any],
              let data = dict["data"] as? [[String: Any]],
              let first = data.first else {
            XCTFail("Expected models list, got \(response)")
            return
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(dict["object"] as? String, "list")
        XCTAssertEqual(first["id"] as? String, "apple-foundation-3b")
        XCTAssertEqual(first["object"] as? String, "model")
        XCTAssertEqual(first["owned_by"] as? String, "apple")
    }

    func testChatCompletionImagePartReturns400() async throws {
        let handlers = FoundationHandlers()
        let body: [String: Any] = [
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "describe this"],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,iVBORw0KGgo="]],
                ],
            ]],
        ]
        let response = try await handlers.handleChatCompletion(body: body, ctx: ctx())
        if case .error(let status, let message) = response {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(
                message.contains("Image input not supported by Apple Foundation Models"),
                "Expected spec §8.5 image-rejection wording, got: \(message)"
            )
        } else {
            XCTFail("Expected .error(400, ...), got \(response)")
        }
    }

    func testChatCompletionAudioPartReturns400() async throws {
        let handlers = FoundationHandlers()
        let body: [String: Any] = [
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "input_audio", "input_audio": ["data": "AAAA", "format": "pcm16"]],
                    ["type": "text", "text": "transcribe"],
                ],
            ]],
        ]
        let response = try await handlers.handleChatCompletion(body: body, ctx: ctx())
        if case .error(let status, let message) = response {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(
                message.contains("Audio input not supported by Apple Foundation Models"),
                "Expected spec §8.5 audio-rejection wording, got: \(message)"
            )
        } else {
            XCTFail("Expected .error(400, ...), got \(response)")
        }
    }

    func testChatCompletionMissingMessagesReturns400() async throws {
        let handlers = FoundationHandlers()
        // Body without a 'messages' key — must short-circuit to 400 before
        // any session work, mirroring LlamaHandlers' behaviour.
        let response = try await handlers.handleChatCompletion(body: [:], ctx: ctx())
        if case .error(let status, let message) = response {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(
                message.contains("Missing 'messages'"),
                "Expected missing-messages 400, got: \(message)"
            )
        } else {
            XCTFail("Expected .error(400, ...), got \(response)")
        }
    }

    func testChatCompletionEmptyMessagesReturns400() async throws {
        let handlers = FoundationHandlers()
        // Empty messages array — must short-circuit to 400 before any
        // session work. Without this guard the prompt would be empty and
        // Apple FM behaviour is undefined.
        let body: [String: Any] = ["messages": [[String: Any]]()]
        let response = try await handlers.handleChatCompletion(body: body, ctx: ctx())
        if case .error(let status, let message) = response {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(
                message.contains("Empty messages"),
                "Expected empty-messages 400, got: \(message)"
            )
        } else {
            XCTFail("Expected .error(400, ...), got \(response)")
        }
    }
}
#else
// macOS host without FoundationModels — tests compile out at this guard.
// The smoke test (in SmokeTest.swift) still runs.
#endif
