// examples/ios-llama/Tests/IOSLlamaAppTests/SmokeTests.swift
//
// Smoke test for the ios-llama example. Verifies that the bridge can
// be started against a real GGUF model and that the local
// OpenAI-compatible endpoint returns a non-empty completion.
//
// Skips cleanly when SMOKE_MODEL_URL / SMOKE_MODEL_SHA256 aren't set;
// CI populates these via scripts/smoke.local.env.

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

    func testLlamaSmoke() async throws {
        let env = SmokeEnv.load()
        guard let urlStr = env["SMOKE_MODEL_URL"], !urlStr.isEmpty,
              let sha = env["SMOKE_MODEL_SHA256"], !sha.isEmpty,
              let url = URL(string: urlStr)
        else {
            throw XCTSkip("SMOKE_MODEL_URL/SMOKE_MODEL_SHA256 not set; skipping ios-llama smoke")
        }

        let download = try await DVAIBridge.shared.downloadModel(.init(
            url: url,
            sha256: sha.lowercased(),
            destFilename: "ios-llama-smoke.gguf"
        ))

        #if targetEnvironment(simulator)
        let gpuLayers = 0
        #else
        let gpuLayers = 99
        #endif
        let server = try await DVAIBridge.shared.start(.init(
            backend: .llama,
            modelPath: download.path,
            gpuLayers: gpuLayers,
            contextSize: 1024
        ))
        XCTAssertEqual(server.backend, .llama)

        let response = try await SmokeHttp.postChatCompletion(
            baseUrl: server.baseUrl,
            messages: [["role": "user", "content": "What is 2+2?"]]
        )
        XCTAssertFalse(response.isEmpty, "llama completion should not be empty")
    }
}
