import XCTest
@testable import DVAIBridge

final class DVAIBridgeAPIShapeTests: XCTestCase {
    func testSingletonExists() {
        let bridge: DVAIBridge = DVAIBridge.shared
        XCTAssertNotNil(bridge)
    }

    func testStatusBeforeStartReportsNotRunning() async {
        let bridge = DVAIBridge()  // fresh instance for test isolation
        let info = await bridge.status()
        XCTAssertFalse(info.running)
        XCTAssertNil(info.backend)
        XCTAssertNil(info.baseUrl)
    }

    func testStopWhenNotStartedIsIdempotent() async throws {
        let bridge = DVAIBridge()
        try await bridge.stop()
        try await bridge.stop()  // no throw
    }

    func testStartCoreMLThrowsBackendUnavailable() async {
        let bridge = DVAIBridge()
        do {
            _ = try await bridge.start(.init(backend: .coreml))
            XCTFail("Expected throw")
        } catch let err as DVAIBridgeError {
            if case .backendUnavailable(.coreml, _) = err { /* expected */ } else {
                XCTFail("wrong error: \(err)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
