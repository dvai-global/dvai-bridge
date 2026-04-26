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
        let env = Self.loadSmokeEnv()
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

    /// Vision smoke: download model + mmproj, load both, run a chat
    /// completion against the tiny test image fixture. Skips cleanly if any
    /// of SMOKE_VISION_MODEL_URL / SMOKE_VISION_MODEL_SHA256 /
    /// SMOKE_VISION_MMPROJ_URL / SMOKE_VISION_MMPROJ_SHA256 are unset.
    func testSmokeVisionEndToEnd() async throws {
        let env = Self.loadSmokeEnv()
        guard let modelUrlStr = env["SMOKE_VISION_MODEL_URL"], !modelUrlStr.isEmpty,
              let modelSha = env["SMOKE_VISION_MODEL_SHA256"], !modelSha.isEmpty,
              let mmprojUrlStr = env["SMOKE_VISION_MMPROJ_URL"], !mmprojUrlStr.isEmpty,
              let mmprojSha = env["SMOKE_VISION_MMPROJ_SHA256"], !mmprojSha.isEmpty,
              let modelUrl = URL(string: modelUrlStr),
              let mmprojUrl = URL(string: mmprojUrlStr)
        else {
            throw XCTSkip("SMOKE_VISION_* env vars not all set; skipping vision smoke")
        }

        let downloader = ModelDownloader(cacheDirOverride: tempDir)
        let modelResult = try await downloader.downloadModel(
            url: modelUrl,
            expectedSha256: modelSha.lowercased(),
            destFilename: "smoke-vision-model.gguf",
            headers: [:],
            onProgress: { _, _ in /* no-op for smoke */ }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelResult.path))
        let mmprojResult = try await downloader.downloadModel(
            url: mmprojUrl,
            expectedSha256: mmprojSha.lowercased(),
            destFilename: "smoke-vision-mmproj.gguf",
            headers: [:],
            onProgress: { _, _ in /* no-op for smoke */ }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: mmprojResult.path))

        let bridge = LlamaCppBridge()
        self.bridge = bridge
        try bridge.loadModel(
            atPath: modelResult.path,
            mmprojPath: nil,
            gpuLayers: 99,
            contextSize: 4096,
            threads: 4,
            embeddingMode: false
        )
        XCTAssertTrue(bridge.isLoaded)
        try bridge.loadMmproj(atPath: mmprojResult.path)
        XCTAssertTrue(bridge.isMmprojLoaded)

        // Read the tiny PNG fixture (1x1 transparent pixel).
        let imageURL = fixturesURL().appendingPathComponent("images").appendingPathComponent("tiny-test.png")
        let imageData = try Data(contentsOf: imageURL)

        // Build a marker-bearing prompt and apply the model's chat template.
        let messages: [[String: String]] = [
            ["role": "user", "content": "Describe this image: \(MTMD_MEDIA_MARKER)"]
        ]
        let chatPrompt = try bridge.applyChatTemplate(nil, messages: messages, addAssistant: true)
        XCTAssertFalse(chatPrompt.isEmpty)

        let completion = try bridge.completeMultimodalPrompt(
            chatPrompt,
            media: [imageData],
            maxTokens: 32,
            temperature: 0.0,
            topP: 1.0
        )
        XCTAssertFalse(completion.isEmpty, "vision completion should not be empty")
    }

    /// Audio smoke: same as vision, but with the WAV fixture instead of PNG.
    /// mtmd's `mtmd_helper_bitmap_init_from_buf` accepts wav/mp3/flac for
    /// audio (per mtmd-helper.h docs). Skips when the model declared no
    /// audio encoder (e.g. vision-only mmproj).
    func testSmokeAudioEndToEnd() async throws {
        let env = Self.loadSmokeEnv()
        guard let modelUrlStr = env["SMOKE_VISION_MODEL_URL"], !modelUrlStr.isEmpty,
              let modelSha = env["SMOKE_VISION_MODEL_SHA256"], !modelSha.isEmpty,
              let mmprojUrlStr = env["SMOKE_VISION_MMPROJ_URL"], !mmprojUrlStr.isEmpty,
              let mmprojSha = env["SMOKE_VISION_MMPROJ_SHA256"], !mmprojSha.isEmpty,
              let modelUrl = URL(string: modelUrlStr),
              let mmprojUrl = URL(string: mmprojUrlStr)
        else {
            throw XCTSkip("SMOKE_VISION_* env vars not all set; skipping audio smoke")
        }

        let downloader = ModelDownloader(cacheDirOverride: tempDir)
        let modelResult = try await downloader.downloadModel(
            url: modelUrl,
            expectedSha256: modelSha.lowercased(),
            destFilename: "smoke-audio-model.gguf",
            headers: [:],
            onProgress: { _, _ in /* no-op for smoke */ }
        )
        let mmprojResult = try await downloader.downloadModel(
            url: mmprojUrl,
            expectedSha256: mmprojSha.lowercased(),
            destFilename: "smoke-audio-mmproj.gguf",
            headers: [:],
            onProgress: { _, _ in /* no-op for smoke */ }
        )

        let bridge = LlamaCppBridge()
        self.bridge = bridge
        try bridge.loadModel(
            atPath: modelResult.path,
            mmprojPath: nil,
            gpuLayers: 99,
            contextSize: 4096,
            threads: 4,
            embeddingMode: false
        )
        try bridge.loadMmproj(atPath: mmprojResult.path)

        // Skip cleanly if the loaded mmproj has no audio encoder (e.g. when
        // SMOKE_VISION_* points at a vision-only projector).
        guard bridge.hasAudioEncoder() else {
            throw XCTSkip("Loaded mmproj reports no audio encoder; skipping audio smoke")
        }

        let audioURL = fixturesURL().appendingPathComponent("audio").appendingPathComponent("wav-1s-16khz-mono.wav")
        let audioData = try Data(contentsOf: audioURL)

        let messages: [[String: String]] = [
            ["role": "user", "content": "Transcribe this: \(MTMD_MEDIA_MARKER)"]
        ]
        let chatPrompt = try bridge.applyChatTemplate(nil, messages: messages, addAssistant: true)

        let completion = try bridge.completeMultimodalPrompt(
            chatPrompt,
            media: [audioData],
            maxTokens: 32,
            temperature: 0.0,
            topP: 1.0
        )
        XCTAssertFalse(completion.isEmpty, "audio completion should not be empty")
    }

    /// Walks up from #file to find the repo-root `fixtures/` dir.
    private func fixturesURL() -> URL {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("fixtures").path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path {
                fatalError("fixtures dir not found walking up from \(#file)")
            }
            dir = parent
        }
        return dir.appendingPathComponent("fixtures")
    }

    /// Reads SMOKE_* env vars from the test process's environment first,
    /// then falls back to the per-developer `scripts/smoke.local.env`
    /// file on the host filesystem. The fallback exists because
    /// `xcodebuild test` does not propagate parent-process env vars
    /// (or `SIMCTL_CHILD_*` / `TEST_RUNNER_*`) to the unit-test bundle's
    /// `ProcessInfo.processInfo.environment` — that's an XCUITest-only
    /// channel. Reading the file directly works reliably both locally
    /// (via the gitignored smoke.local.env) and in CI (which actually
    /// does inject env vars at the workflow level — `ProcessInfo` sees
    /// those because the Mac runner inherits the GitHub Actions step env
    /// before xcodebuild starts).
    fileprivate static func loadSmokeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("SMOKE_") }
        if !env.isEmpty {
            return env
        }
        // Walk up from this file to find `scripts/smoke.local.env`.
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts/smoke.local.env").path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path {
                return env  // empty
            }
            dir = parent
        }
        let envFile = dir.appendingPathComponent("scripts/smoke.local.env")
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else {
            return env
        }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // Strip a single matching pair of leading/trailing quotes so a
            // developer writing `SMOKE_MODEL_URL="https://..."` in the env
            // file doesn't end up with the quote chars baked into the URL
            // (which makes `URL(string:)` return nil and the test silently
            // skip with a confusing reason).
            if value.count >= 2 {
                if (value.first == "\"" && value.last == "\"") ||
                   (value.first == "'" && value.last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            if key.hasPrefix("SMOKE_") && !value.isEmpty {
                env[key] = value
            }
        }
        return env
    }
}
