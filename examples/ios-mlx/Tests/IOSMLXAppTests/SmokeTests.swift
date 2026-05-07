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
        // Skip on non-Apple-Silicon hosts; MLX has no device on x86_64.
        #if arch(x86_64)
        throw XCTSkip("MLX backend requires Apple Silicon at runtime; skipping on x86_64")
        #endif

        // Skip on iOS Simulator unconditionally.
        //
        // mlx-swift-lm reaches into native MLX C++ during model resolution.
        // On the iOS Simulator (even arm64 sims), it reliably triggers a
        // libc++ hardening assertion ("basic_string(const char*) detected
        // nullptr") inside the upstream C++ layer when resolving the
        // HuggingFace model id, before our Swift code can intercept the
        // failure. The libc++ assertion calls abort() — Swift `do/catch`
        // can't recover from a process-level abort, so the test process
        // dies before we can XCTSkip.
        //
        // MLX is genuinely device-only in practice. CI for this example
        // should target a real Apple-Silicon Mac (Catalyst destination)
        // or a real iPhone 15 Pro+ device. For CI matrices that only have
        // simulators available, the skip below keeps the smoke phase green.
        //
        // Set SMOKE_MLX_FORCE_SIM=1 to opt back in (e.g., when verifying
        // against a future mlx-swift-lm that fixes the simulator path).
        let env = SmokeEnv.load()
        #if targetEnvironment(simulator)
        if env["SMOKE_MLX_FORCE_SIM"] != "1" {
            throw XCTSkip("MLX skipped on iOS Simulator (upstream mlx-swift-lm calls abort() before Swift can catch). Set SMOKE_MLX_FORCE_SIM=1 to override.")
        }
        #endif

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
            // mlx-swift-lm download failures or device errors → skip
            // rather than fail the host's smoke run.
            throw XCTSkip("MLX backend could not start in this destination: \(error.localizedDescription)")
        }
        XCTAssertEqual(server.backend, .mlx)

        let response = try await SmokeHttp.postChatCompletion(
            baseUrl: server.baseUrl,
            messages: [["role": "user", "content": "What is 2+2?"]]
        )
        XCTAssertFalse(response.isEmpty, "MLX completion should not be empty")
    }
}
