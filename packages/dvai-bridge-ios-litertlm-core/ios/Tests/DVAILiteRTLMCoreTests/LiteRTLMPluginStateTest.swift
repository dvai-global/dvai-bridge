// Smoke test for DVAILiteRTLMCore. Real model load is gated behind
// an env-var so CI runs (and dev machines without the model cached)
// don't hang for minutes downloading weights.

import XCTest
@testable import DVAILiteRTLMCore

final class LiteRTLMPluginStateTest: XCTestCase {
    func testStatusInfoBeforeStartReportsNotRunning() async {
        let state = LiteRTLMPluginState()
        let info = await state.statusInfo()
        XCTAssertEqual(info["running"] as? Bool, false)
        XCTAssertNil(info["backend"])
        XCTAssertNil(info["baseUrl"])
    }

    func testStartWithoutModelPathThrows() async {
        let state = LiteRTLMPluginState()
        do {
            _ = try await state.start(opts: [:])
            XCTFail("expected start without modelPath to throw")
        } catch {
            XCTAssertTrue("\(error)".contains("modelPath"), "error should mention missing modelPath: \(error)")
        }
    }

    /// Gemma template shape. Mirrors the JS test in @dvai-bridge/core so
    /// the two backends stay behaviourally aligned.
    func testFlattenMessagesUsesGemmaTemplate() {
        let prompt = LiteRTLMHandlers.flattenMessagesToPrompt([
            ["role": "system",    "content": "You are helpful."],
            ["role": "user",      "content": "hi"],
            ["role": "assistant", "content": "hello"],
            ["role": "user",      "content": "how are you?"],
        ])
        XCTAssertTrue(prompt.contains("<start_of_turn>user\nYou are helpful."))
        XCTAssertTrue(prompt.contains("<start_of_turn>user\nhi"))
        XCTAssertTrue(prompt.contains("<start_of_turn>model\nhello"))
        XCTAssertTrue(prompt.contains("<start_of_turn>user\nhow are you?"))
        XCTAssertTrue(prompt.hasSuffix("<start_of_turn>model\n"))
    }

    /// End-to-end test against a real LiteRT-LM model. Skipped unless
    /// `SMOKE_LITERTLM_MODEL_PATH` is set to a `.litertlm` file. The
    /// file must exist at that absolute path — LiteRT-LM doesn't do
    /// HF-style downloads on the Swift side.
    func testStartWithRealModel() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelPath = env["SMOKE_LITERTLM_MODEL_PATH"], !modelPath.isEmpty else {
            throw XCTSkip("SMOKE_LITERTLM_MODEL_PATH not set; skipping LiteRT-LM real-model test")
        }
        let state = LiteRTLMPluginState()
        let result = try await state.start(opts: ["modelPath": modelPath])
        defer { Task { try? await state.stop() } }
        XCTAssertEqual(result["backend"] as? String, "litertlm")
        XCTAssertEqual(result["modelId"] as? String, modelPath)
        XCTAssertNotNil(result["baseUrl"])
    }
}
