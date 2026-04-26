// Tests/DVAICapacitorLlamaTests/RealModelSmokeTest.swift
//
// End-to-end smoke test against a small public GGUF model. Verifies
// mechanics (download → load → respond → free) only, not output quality.
//
// The test reads `SMOKE_MODEL_URL` and `SMOKE_MODEL_SHA256` from the
// process environment. When either is missing, it skips cleanly via
// `XCTSkip`, so this file is safe to compile and run locally even
// without those env vars set.
//
// On the self-hosted Mac runner the workflow forwards the secrets to
// the simulator via `SIMCTL_CHILD_SMOKE_MODEL_URL=...` (xcodebuild's
// documented mechanism for env vars to reach the simulator-hosted
// XCTest process).

import XCTest
@testable import DVAICapacitorLlama
import DVAICapacitorLlamaObjC

final class RealModelSmokeTest: XCTestCase {
    private var tempDir: URL!
    private var bridge: LlamaCppBridge?

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dvai-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempDir = base
    }

    override func tearDownWithError() throws {
        bridge?.unload()
        bridge = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    func testSmokeRealModelEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let urlStr = env["SMOKE_MODEL_URL"], !urlStr.isEmpty,
              let sha = env["SMOKE_MODEL_SHA256"], !sha.isEmpty,
              let url = URL(string: urlStr)
        else {
            throw XCTSkip("SMOKE_MODEL_URL/SMOKE_MODEL_SHA256 not set in env; skipping real-model smoke")
        }

        // Generous timeout for the 800 MB download + 1B-param load.
        let downloader = ModelDownloader(cacheDirOverride: tempDir)
        let result = try await downloader.downloadModel(
            url: url,
            expectedSha256: sha.lowercased(),
            destFilename: "smoke-model.gguf",
            headers: [:],
            onProgress: { _, _ in /* no-op for smoke */ }
        )

        XCTAssertFalse(result.cached, "first download into a fresh temp dir should not be cached")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.path),
            "downloaded file should exist at \(result.path)"
        )

        let bridge = LlamaCppBridge()
        self.bridge = bridge
        try bridge.loadModel(
            atPath: result.path,
            mmprojPath: nil,
            gpuLayers: 99,
            contextSize: 2048,
            threads: 4,
            embeddingMode: false
        )
        XCTAssertTrue(bridge.isLoaded, "model should be loaded after loadModel(...) returns")

        let completion = try bridge.completePrompt(
            "<|begin_of_text|>What is 2+2?",
            maxTokens: 32,
            temperature: 0.0,
            topP: 1.0
        )
        // Don't assert specific content — that's quality testing, not smoke.
        XCTAssertFalse(completion.isEmpty, "completion should not be empty")
    }
}
