// examples/ios-mlx/Tests/IOSMLXAppTests/SmokeTests.swift
//
// Smoke for ios-mlx. MLX is Apple Silicon-only at runtime — Intel Mac
// hosts and Intel-host iOS Simulator destinations skip cleanly.

import XCTest
import DVAIBridge

final class SmokeTests: XCTestCase {

    override class var defaultTestSuite: XCTestSuite {
        let suite = super.defaultTestSuite
        for case let testCase as XCTestCase in suite.tests {
            testCase.executionTimeAllowance = 30 * 60
        }
        return suite
    }

    override func tearDown() async throws {
        try? await DVAIBridge.shared.stop()
    }

    func testMLXSmoke() async throws {
        // Skip on non-Apple-Silicon hosts; the MLX backend has no
        // device on x86_64 simulators.
        #if arch(x86_64)
        throw XCTSkip("MLX backend requires Apple Silicon at runtime; skipping on x86_64")
        #else
        let env = SmokeEnv.load()
        // Allow CI to override the model id via env (smaller checkpoints
        // for faster CI runs); default to the README's reference.
        let modelId = env["SMOKE_MLX_MODEL_ID"] ?? "mlx-community/Llama-3.2-3B-Instruct-4bit"

        let server: BoundServer
        do {
            server = try await DVAIBridge.shared.start(.init(
                backend: .mlx,
                modelPath: modelId,
                contextSize: 1024
            ))
        } catch {
            // mlx-swift-lm download failures or simulator-side missing
            // device errors → skip rather than fail the host's smoke run.
            throw XCTSkip("MLX backend could not start in this destination: \(error.localizedDescription)")
        }
        XCTAssertEqual(server.backend, .mlx)

        let response = try await SmokeHttp.postChatCompletion(
            baseUrl: server.baseUrl,
            messages: [["role": "user", "content": "What is 2+2?"]]
        )
        XCTAssertFalse(response.isEmpty, "MLX completion should not be empty")
        #endif
    }
}
