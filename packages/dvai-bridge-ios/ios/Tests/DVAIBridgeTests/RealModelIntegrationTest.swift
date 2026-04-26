// Tests/DVAIBridgeTests/RealModelIntegrationTest.swift
//
// End-to-end integration tests for the iOS native SDK against real models.
// Each backend has its own test method; each skips cleanly when its
// prereqs aren't met (env vars missing, iOS version too old, etc.).
//
// Pattern mirrors Phase 2C's RealModelSmokeTest in capacitor-llama.

import XCTest
import CommonCrypto
import DVAIBridge
import DVAILlamaCore

final class RealModelIntegrationTest: XCTestCase {
    private var tempDir: URL!

    override class var defaultTestSuite: XCTestSuite {
        let suite = super.defaultTestSuite
        for case let testCase as XCTestCase in suite.tests {
            testCase.executionTimeAllowance = 30 * 60   // generous for slow downloads
        }
        return suite
    }

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dvai-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempDir = base
    }

    override func tearDown() async throws {
        try? await DVAIBridge.shared.stop()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    // MARK: - Llama backend (uses Phase 2C's existing SMOKE_MODEL_URL)

    func testLlamaBackendIntegration() async throws {
        let env = Self.loadSmokeEnv()
        guard let urlStr = env["SMOKE_MODEL_URL"], !urlStr.isEmpty,
              let sha = env["SMOKE_MODEL_SHA256"], !sha.isEmpty,
              let url = URL(string: urlStr)
        else {
            throw XCTSkip("SMOKE_MODEL_URL/SMOKE_MODEL_SHA256 not set; skipping llama integration")
        }

        let downloadResult = try await DVAIBridge.shared.downloadModel(.init(
            url: url,
            sha256: sha.lowercased(),
            destFilename: "int-llama.gguf"
        ))

        // gpuLayers=0 on simulator (no Metal), 99 on device/host.
        #if targetEnvironment(simulator)
        let gpuLayers = 0
        #else
        let gpuLayers = 99
        #endif
        let server = try await DVAIBridge.shared.start(.init(
            backend: .llama,
            modelPath: downloadResult.path,
            gpuLayers: gpuLayers,
            contextSize: 1024
        ))
        XCTAssertEqual(server.backend, .llama)

        let response = try await postChatCompletion(
            baseUrl: server.baseUrl,
            messages: [["role": "user", "content": "What is 2+2?"]]
        )
        XCTAssertFalse(response.isEmpty, "llama completion should not be empty")
    }

    // MARK: - Foundation Models backend (iOS 26+ runtime)

    func testFoundationBackendIntegration() async throws {
        if #available(iOS 26.0, macOS 26.0, *) {
            // Continue
        } else {
            throw XCTSkip("Foundation Models requires iOS 26+ at runtime")
        }

        let server = try await DVAIBridge.shared.start(.init(backend: .foundation))
        XCTAssertEqual(server.backend, .foundation)

        let response = try await postChatCompletion(
            baseUrl: server.baseUrl,
            messages: [["role": "user", "content": "Hello"]]
        )
        XCTAssertFalse(response.isEmpty, "foundation completion should not be empty")
    }

    // MARK: - CoreML backend (new SMOKE_COREML_* env vars)

    @available(iOS 18.0, macOS 15.0, *)
    func testCoreMLBackendIntegration() async throws {
        let env = Self.loadSmokeEnv()
        guard let modelUrlStr = env["SMOKE_COREML_MODEL_URL"], !modelUrlStr.isEmpty,
              let modelSha = env["SMOKE_COREML_MODEL_SHA256"], !modelSha.isEmpty,
              let tokUrlStr = env["SMOKE_COREML_TOKENIZER_URL"], !tokUrlStr.isEmpty,
              let tokSha = env["SMOKE_COREML_TOKENIZER_SHA256"], !tokSha.isEmpty,
              let modelUrl = URL(string: modelUrlStr),
              let tokUrl = URL(string: tokUrlStr)
        else {
            throw XCTSkip("SMOKE_COREML_* env vars not all set; skipping CoreML integration")
        }
        let hfToken = env["SMOKE_HF_TOKEN"]

        // 1. Download the .mlmodelc.zip + tokenizer.json
        let modelZip = try await downloadFile(
            url: modelUrl,
            sha256: modelSha,
            destFilename: "model.mlmodelc.zip",
            authBearer: nil
        )
        let tokFile = try await downloadFile(
            url: tokUrl,
            sha256: tokSha,
            destFilename: "tokenizer.json",
            authBearer: hfToken
        )

        // 2. Unzip .mlmodelc — Process is unavailable on iOS, so this
        //    branch only runs when the test bundle is built for the macOS
        //    host (e.g. Mac Catalyst destination). On iOS Simulator the
        //    test skips cleanly.
        //
        //    Phase 3D follow-up: replace `/usr/bin/unzip` with an
        //    in-process unzip path (e.g. Compression framework or a
        //    bundled unzip dependency) so this test can run on the iOS
        //    Simulator destination too.
        #if os(macOS)
        let unzipped = try await unzip(modelZip, into: tempDir)
        #else
        throw XCTSkip("CoreML integration test requires macOS host (iOS simulator lacks Process); Phase 3D follow-up.")
        #endif

        // The zip's top-level dir is "StatefulModel.mlmodelc" or similar;
        // discover the .mlmodelc directory rather than hardcoding the name.
        let mlmodelcURL = try findFirst(extension: "mlmodelc", under: unzipped)

        // 3. Place tokenizer.json + tokenizer_config.json (sibling URL) in a dir
        let tokDir = tempDir.appendingPathComponent("tokenizer")
        try FileManager.default.createDirectory(at: tokDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: tokFile, to: tokDir.appendingPathComponent("tokenizer.json"))
        // tokenizer_config.json is a sibling of tokenizer.json on HF; download it too
        let tokCfgUrl = tokUrl.deletingLastPathComponent().appendingPathComponent("tokenizer_config.json")
        let tokCfgFile = try await downloadFileMaybe(url: tokCfgUrl, authBearer: hfToken)
        if let tokCfgFile {
            try FileManager.default.copyItem(at: tokCfgFile, to: tokDir.appendingPathComponent("tokenizer_config.json"))
        }

        // 4. Boot the bridge against the .coreml backend
        let server = try await DVAIBridge.shared.start(.init(
            backend: .coreml,
            modelPath: mlmodelcURL.path,
            tokenizerPath: tokDir.path
        ))
        XCTAssertEqual(server.backend, .coreml)

        let response = try await postChatCompletion(
            baseUrl: server.baseUrl,
            messages: [["role": "user", "content": "What is 2+2?"]]
        )
        XCTAssertFalse(response.isEmpty, "CoreML completion should not be empty")
    }

    // MARK: - Helpers

    private func postChatCompletion(baseUrl: String, messages: [[String: String]]) async throws -> String {
        let url = URL(string: "\(baseUrl)/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "messages": messages,
            "max_tokens": 32,
            "temperature": 0.0,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Integration", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "POST failed: \(String(data: data, encoding: .utf8) ?? "")"
            ])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        return message ?? ""
    }

    private func downloadFile(url: URL, sha256: String, destFilename: String, authBearer: String?) async throws -> URL {
        var req = URLRequest(url: url)
        if let token = authBearer { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (tempUrl, _) = try await URLSession.shared.download(for: req)
        let dest = tempDir.appendingPathComponent(destFilename)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempUrl, to: dest)
        // sha256 verification — cross-check the downloaded bytes
        try verifySha256(at: dest, expected: sha256.lowercased())
        return dest
    }

    private func downloadFileMaybe(url: URL, authBearer: String?) async throws -> URL? {
        do {
            return try await downloadFile(url: url, sha256: "", destFilename: url.lastPathComponent, authBearer: authBearer)
        } catch {
            return nil   // sibling file is optional
        }
    }

    private func verifySha256(at url: URL, expected: String) throws {
        guard !expected.isEmpty else { return }
        let data = try Data(contentsOf: url)
        let digest = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [UInt8] in
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
            return hash
        }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        if hex != expected {
            throw NSError(domain: "Integration", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "sha256 mismatch: got \(hex), expected \(expected)"])
        }
    }

    private func unzip(_ src: URL, into dest: URL) async throws -> URL {
        // Process / NSTask is macOS-only; on iOS (including the simulator's
        // iOS-flavored test bundle) it's not in the SDK at all. Callers on
        // iOS skip via XCTSkip before reaching here, but the helper itself
        // still needs to compile on iOS — so the body is gated.
        //
        // Phase 3D follow-up: replace `/usr/bin/unzip` with an in-process
        // unzip path so this works on iOS Simulator too.
        #if os(macOS)
        let unzipDir = dest.appendingPathComponent("unzipped")
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", src.path, "-d", unzipDir.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Integration", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "unzip exited with status \(process.terminationStatus)"
            ])
        }
        return unzipDir
        #else
        throw NSError(domain: "Integration", code: -3, userInfo: [
            NSLocalizedDescriptionKey: "unzip helper unavailable on iOS (Process is macOS-only); Phase 3D follow-up."
        ])
        #endif
    }

    private func findFirst(extension ext: String, under root: URL) throws -> URL {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == ext { return url }
        }
        throw NSError(domain: "Integration", code: -4, userInfo: [
            NSLocalizedDescriptionKey: "no .\(ext) found under \(root.path)"
        ])
    }

    /// Reads SMOKE_* env vars from the test process's environment first,
    /// then falls back to scripts/smoke.local.env on the host filesystem.
    /// Same pattern as Phase 2C's RealModelSmokeTest helper.
    fileprivate static func loadSmokeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("SMOKE_") }
        if !env.isEmpty { return env }
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts/smoke.local.env").path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return env }
            dir = parent
        }
        let envFile = dir.appendingPathComponent("scripts/smoke.local.env")
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else { return env }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2 {
                if (value.first == "\"" && value.last == "\"") ||
                   (value.first == "'" && value.last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            if key.hasPrefix("SMOKE_") && !value.isEmpty { env[key] = value }
        }
        return env
    }
}
