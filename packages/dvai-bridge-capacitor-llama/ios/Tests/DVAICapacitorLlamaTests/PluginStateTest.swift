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

    /// With the real LlamaCppBridge implementation, loading a non-existent GGUF
    /// fails at `llama_load_model_from_file`. The full `start → server-bind →
    /// success` happy-path needs a real model file and is exercised by the
    /// device-level tests in Task 37's milestone. Here we assert that the
    /// failure surfaces cleanly and the state stays "not running".
    func testStartFailsOnFakeModelPath() async {
        let state = PluginState()
        do {
            _ = try await state.start(opts: [
                "modelPath": "/tmp/definitely-does-not-exist.gguf",
                "httpBasePort": 39200,
                "httpMaxPortAttempts": 4,
            ])
            XCTFail("expected start() to throw for fake model path")
        } catch {
            // expected
        }
        let info = await state.statusInfo()
        XCTAssertEqual(info["running"] as? Bool, false)
    }
}
