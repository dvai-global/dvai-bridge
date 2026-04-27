// Smoke test for DVAIMLXCore. Real model load is gated behind an
// env-var so CI runs (and dev machines without the model cached)
// don't hang for minutes downloading weights.

import XCTest
@testable import DVAIMLXCore

final class MLXPluginStateTest: XCTestCase {
    func testStatusInfoBeforeStartReportsNotRunning() async {
        let state = MLXPluginState()
        let info = await state.statusInfo()
        XCTAssertEqual(info["running"] as? Bool, false)
        XCTAssertNil(info["backend"])
        XCTAssertNil(info["baseUrl"])
    }

    func testStartWithoutModelPathThrows() async {
        let state = MLXPluginState()
        do {
            _ = try await state.start(opts: [:])
            XCTFail("expected start without modelPath to throw")
        } catch {
            XCTAssertTrue("\(error)".contains("modelPath"), "error should mention missing modelPath: \(error)")
        }
    }

    /// End-to-end test against a real MLX model. Skipped unless
    /// `SMOKE_MLX_MODEL_ID` is set (e.g. "mlx-community/Llama-3.2-1B-Instruct-4bit").
    /// The first run downloads weights into the user's HF cache (~700 MB
    /// for the 1B-4bit). Subsequent runs hit the cache.
    func testStartWithRealModel() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelId = env["SMOKE_MLX_MODEL_ID"], !modelId.isEmpty else {
            throw XCTSkip("SMOKE_MLX_MODEL_ID not set; skipping MLX real-model test")
        }
        let state = MLXPluginState()
        let result = try await state.start(opts: ["modelPath": modelId])
        defer { Task { try? await state.stop() } }
        XCTAssertEqual(result["backend"] as? String, "mlx")
        XCTAssertEqual(result["modelId"] as? String, modelId)
        XCTAssertNotNil(result["baseUrl"])
    }
}
