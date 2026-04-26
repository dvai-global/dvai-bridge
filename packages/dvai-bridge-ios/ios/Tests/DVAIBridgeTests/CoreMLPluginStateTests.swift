import XCTest
@testable import DVAICoreMLCore

@available(iOS 18.0, macOS 15.0, *)
final class CoreMLPluginStateTests: XCTestCase {
    func testStartFailsWithoutModelPath() async {
        let state = CoreMLPluginState()
        do {
            _ = try await state.start(opts: [:])
            XCTFail("Expected throw")
        } catch let err as CoreMLBackendError {
            guard case .modelLoadFailed = err else { return XCTFail("wrong error: \(err)") }
            // Pass — empty opts correctly throws modelLoadFailed
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testStartFailsWithoutTokenizerPath() async {
        let state = CoreMLPluginState()
        do {
            _ = try await state.start(opts: ["modelPath": "/tmp/x.mlmodelc"])
            XCTFail("Expected throw")
        } catch let err as CoreMLBackendError {
            guard case .tokenizerLoadFailed = err else { return XCTFail("wrong error: \(err)") }
            // Pass — missing tokenizerPath correctly throws tokenizerLoadFailed
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testStopWhenNotStartedIsIdempotent() async throws {
        try await CoreMLPluginState().stop()
        // Doesn't throw — idempotent stop is required by the API contract
    }

    func testStatusInfoReportsNotRunning() async {
        let info = await CoreMLPluginState().statusInfo()
        XCTAssertEqual(info["running"] as? Bool, false)
    }
}
