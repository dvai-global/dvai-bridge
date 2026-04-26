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
import DVAILlamaCore
import DVAILlamaCoreObjC

/// Unbuffered breadcrumb. NSLog flushes per call to stderr / oslog, so
/// even if the test process dies mid-step (jetsam SIGKILL on simulator,
/// for example) the most recent step still appears in xcresult /
/// `log show`. Plain `print(...)` buffers on stdout and silently
/// disappears when the process is killed.
@inline(__always)
fileprivate func smokeStep(_ msg: String) {
    NSLog("DVAI-SMOKE: %@", msg)
}

final class RealModelSmokeTest: XCTestCase {
    private var tempDir: URL!
    private var bridge: LlamaCppBridge?

    /// Vision + audio smoke involves downloading a 5 GB GGUF + 557 MB
    /// mmproj plus loading both into the simulator's Metal context and
    /// running an eval pass. The combined runtime can easily exceed
    /// Xcode's default 10-minute per-test allowance, after which xctest
    /// kills and "Restarts" the test bundle. We ask for 45 minutes per
    /// test to absorb slow networks + model load + first-Metal-shader
    /// compile.
    override class var defaultTestSuite: XCTestSuite {
        let suite = super.defaultTestSuite
        for case let testCase as XCTestCase in suite.tests {
            testCase.executionTimeAllowance = 45 * 60
        }
        return suite
    }

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

        smokeStep("vision: downloading main model")
        let downloader = ModelDownloader(cacheDirOverride: tempDir)
        let modelResult = try await downloader.downloadModel(
            url: modelUrl,
            expectedSha256: modelSha.lowercased(),
            destFilename: "smoke-vision-model.gguf",
            headers: [:],
            onProgress: { _, _ in /* no-op for smoke */ }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelResult.path))
        smokeStep("vision: model downloaded; downloading mmproj")
        let mmprojResult = try await downloader.downloadModel(
            url: mmprojUrl,
            expectedSha256: mmprojSha.lowercased(),
            destFilename: "smoke-vision-mmproj.gguf",
            headers: [:],
            onProgress: { _, _ in /* no-op for smoke */ }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: mmprojResult.path))
        smokeStep("vision: mmproj downloaded")

        let bridge = LlamaCppBridge()
        self.bridge = bridge
        // gpuLayers=0 on simulator: same MTLSimDevice allocation cap that
        // hits the mmproj also bites the main model when mtmd_helper_decode
        // builds image-embedding tensors and llama_decode runs them on
        // Metal. Falling back to CPU for the main model avoids the abort.
        // Real iPhone hardware uses Metal end-to-end → gpuLayers=99 is the
        // production default.
        #if targetEnvironment(simulator)
        let mainGPULayers: Int32 = 0
        #else
        let mainGPULayers: Int32 = 99
        #endif
        smokeStep("vision: loading main model (gpuLayers=\(mainGPULayers))")
        try bridge.loadModel(
            atPath: modelResult.path,
            mmprojPath: nil,
            // Smoke: small context to keep KV-cache memory well under
            // the simulator's per-process budget. We sample at most 32
            // tokens, so 1024 leaves plenty of headroom for the prompt
            // + image chunk + completion without paging.
            gpuLayers: mainGPULayers,
            contextSize: 1024,
            threads: 4,
            embeddingMode: false
        )
        XCTAssertTrue(bridge.isLoaded)
        smokeStep("vision: main model loaded")
        // useGPU=false on simulator: iOS Simulator's MTLSimDevice aborts in
        // _xpc_shmem_create_with_prot when CLIP tries to allocate the
        // ~60 MiB position-embedding tensor (gemma4v has shape [768, 10240, 2]).
        // CPU-only projection is slow but lets the smoke run end-to-end.
        // Real iPhone hardware uses Metal without issue → useGPU=true is the
        // production default.
        #if targetEnvironment(simulator)
        let useGPUForMmproj = false
        #else
        let useGPUForMmproj = true
        #endif
        smokeStep("vision: loading mmproj (useGPU=\(useGPUForMmproj))")
        try bridge.loadMmproj(atPath: mmprojResult.path, useGPU: useGPUForMmproj)
        XCTAssertTrue(bridge.isMmprojLoaded)
        smokeStep("vision: mmproj loaded")

        // Read the smoke PNG fixture. tiny-test.png is a 256x256 image with
        // three primary-colour squares + a yellow ellipse — picked so a
        // captioner has unambiguous content to describe (a blank canvas
        // tends to make Gemma 4 emit `<end_of_turn>` as its first sample,
        // which the greedy sampler treats as a clean exit and returns "").
        // Regenerate via `scripts/generate-image-fixtures.sh`.
        let imageURL = fixturesURL().appendingPathComponent("images").appendingPathComponent("tiny-test.png")
        let imageData = try Data(contentsOf: imageURL)

        // Build a marker-bearing prompt and apply the model's chat template.
        // Gemma 4's published GGUFs at ggml-org/gemma-4-E2B-it-GGUF do not
        // embed a tokenizer.chat_template that llama.cpp's heuristic
        // recognizes, so passing nil here produces error 41 ("model has no
        // chat template and none provided"). Production developers using
        // capacitor-llama are expected to supply their model's template at
        // start time; for smoke purposes we hardcode Gemma's published
        // chat-template format inline.
        let gemmaTemplate = """
        {% for m in messages %}<start_of_turn>{% if m.role == 'assistant' %}model{% else %}{{ m.role }}{% endif %}
        {{ m.content }}<end_of_turn>
        {% endfor %}{% if add_generation_prompt %}<start_of_turn>model
        {% endif %}
        """
        let messages: [[String: String]] = [
            ["role": "user", "content": "Describe this image: \(MTMD_MEDIA_MARKER)"]
        ]
        let chatPrompt = try bridge.applyChatTemplate(gemmaTemplate, messages: messages, addAssistant: true)
        XCTAssertFalse(chatPrompt.isEmpty)
        smokeStep("vision: chat template applied; running multimodal eval")

        let completion = try bridge.completeMultimodalPrompt(
            chatPrompt,
            media: [imageData],
            maxTokens: 32,
            temperature: 0.0,
            topP: 1.0
        )
        smokeStep("vision: eval done — completion=\(completion.prefix(80))")
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

        smokeStep("audio: downloading main model")
        let downloader = ModelDownloader(cacheDirOverride: tempDir)
        let modelResult = try await downloader.downloadModel(
            url: modelUrl,
            expectedSha256: modelSha.lowercased(),
            destFilename: "smoke-audio-model.gguf",
            headers: [:],
            onProgress: { _, _ in /* no-op for smoke */ }
        )
        smokeStep("audio: model downloaded; downloading mmproj")
        let mmprojResult = try await downloader.downloadModel(
            url: mmprojUrl,
            expectedSha256: mmprojSha.lowercased(),
            destFilename: "smoke-audio-mmproj.gguf",
            headers: [:],
            onProgress: { _, _ in /* no-op for smoke */ }
        )
        smokeStep("audio: mmproj downloaded")

        let bridge = LlamaCppBridge()
        self.bridge = bridge
        // gpuLayers=0 on simulator: same MTLSimDevice allocation cap that
        // hits the mmproj also bites the main model when mtmd_helper_decode
        // builds audio-embedding tensors and llama_decode runs them on
        // Metal. Falling back to CPU for the main model avoids the abort.
        #if targetEnvironment(simulator)
        let mainGPULayers: Int32 = 0
        #else
        let mainGPULayers: Int32 = 99
        #endif
        smokeStep("audio: loading main model (gpuLayers=\(mainGPULayers))")
        try bridge.loadModel(
            atPath: modelResult.path,
            mmprojPath: nil,
            gpuLayers: mainGPULayers,
            contextSize: 1024,
            threads: 4,
            embeddingMode: false
        )
        smokeStep("audio: main model loaded")
        // useGPU=false on simulator: iOS Simulator's MTLSimDevice aborts in
        // _xpc_shmem_create_with_prot when CLIP tries to allocate the
        // ~60 MiB position-embedding tensor (gemma4v has shape [768, 10240, 2]).
        // CPU-only projection is slow but lets the smoke run end-to-end.
        // Real iPhone hardware uses Metal without issue → useGPU=true is the
        // production default.
        #if targetEnvironment(simulator)
        let useGPUForMmproj = false
        #else
        let useGPUForMmproj = true
        #endif
        smokeStep("audio: loading mmproj (useGPU=\(useGPUForMmproj))")
        try bridge.loadMmproj(atPath: mmprojResult.path, useGPU: useGPUForMmproj)
        smokeStep("audio: mmproj loaded")

        // Skip cleanly if the loaded mmproj has no audio encoder (e.g. when
        // SMOKE_VISION_* points at a vision-only projector).
        guard bridge.hasAudioEncoder() else {
            throw XCTSkip("Loaded mmproj reports no audio encoder; skipping audio smoke")
        }
        smokeStep("audio: hasAudioEncoder=true; running multimodal eval")

        let audioURL = fixturesURL().appendingPathComponent("audio").appendingPathComponent("wav-1s-16khz-mono.wav")
        let audioData = try Data(contentsOf: audioURL)

        // Same Gemma chat template as the vision test — Gemma 4 GGUFs at
        // ggml-org don't ship a llama.cpp-recognized chat_template.
        let gemmaTemplate = """
        {% for m in messages %}<start_of_turn>{% if m.role == 'assistant' %}model{% else %}{{ m.role }}{% endif %}
        {{ m.content }}<end_of_turn>
        {% endfor %}{% if add_generation_prompt %}<start_of_turn>model
        {% endif %}
        """
        // Open-ended prompt: the WAV fixture is a synthetic 1-second 440 Hz
        // sine tone with no speech content, so "Transcribe this:" makes the
        // model emit `<end_of_turn>` as its first sample (legitimate — there's
        // nothing to transcribe). "Describe what you hear" gives Gemma room
        // to say something like "A pure tone." instead of bailing immediately.
        let messages: [[String: String]] = [
            ["role": "user", "content": "Describe what you hear: \(MTMD_MEDIA_MARKER)"]
        ]
        let chatPrompt = try bridge.applyChatTemplate(gemmaTemplate, messages: messages, addAssistant: true)

        // Note: we do NOT assert that the completion is non-empty. With a
        // synthetic tone fixture, an immediate-EOS sample is a *correct*
        // model response, not a pipeline failure. This smoke verifies that
        // the audio path runs end-to-end without throwing — eval, decode,
        // and sampler all return cleanly. Production code paths (real
        // speech audio) are exercised by host-app integration tests.
        _ = try bridge.completeMultimodalPrompt(
            chatPrompt,
            media: [audioData],
            maxTokens: 32,
            temperature: 0.0,
            topP: 1.0
        )
        smokeStep("audio: eval done")
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
