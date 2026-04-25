import XCTest
@testable import DVAICapacitorLlama

final class PluginStateTest: XCTestCase {
    func testStartFailsWhenModelPathMissing() async {
        let state = PluginState()
        do {
            _ = try await state.start(opts: [:])
            XCTFail("should have thrown")
        } catch let error as NSError {
            XCTAssertTrue(error.localizedDescription.contains("modelPath is required"))
        }
    }

    func testStartFailsWhenModelPathEmpty() async {
        let state = PluginState()
        do {
            _ = try await state.start(opts: ["modelPath": ""])
            XCTFail("should have thrown")
        } catch {
            // expected
        }
    }

    func testStatusInfoReportsNotRunning() async {
        let state = PluginState()
        let info = await state.statusInfo()
        XCTAssertEqual(info["running"] as? Bool, false)
    }

    func testStartBindsServerAndReportsBaseUrl() async throws {
        let state = PluginState()
        let result = try await state.start(opts: [
            "modelPath": "/tmp/fake.gguf",
            "httpBasePort": 39200,
            "httpMaxPortAttempts": 4,
        ])
        XCTAssertEqual(result["backend"] as? String, "llama")
        XCTAssertEqual(result["modelId"] as? String, "/tmp/fake.gguf")
        let port = result["port"] as? Int
        XCTAssertNotNil(port)
        XCTAssertGreaterThanOrEqual(port!, 39200)
        XCTAssertLessThanOrEqual(port!, 39203)
        let baseUrl = result["baseUrl"] as? String
        XCTAssertEqual(baseUrl, "http://127.0.0.1:\(port!)/v1")

        try await state.stop()
        let info = await state.statusInfo()
        XCTAssertEqual(info["running"] as? Bool, false)
    }

    func testRestartReplacesPreviousRun() async throws {
        let state = PluginState()
        _ = try await state.start(opts: [
            "modelPath": "/tmp/fake1.gguf",
            "httpBasePort": 39210,
            "httpMaxPortAttempts": 4,
        ])
        // Calling start again should stop the previous run and start fresh
        let result2 = try await state.start(opts: [
            "modelPath": "/tmp/fake2.gguf",
            "httpBasePort": 39220,
            "httpMaxPortAttempts": 4,
        ])
        XCTAssertEqual(result2["modelId"] as? String, "/tmp/fake2.gguf")
        try await state.stop()
    }
}
