import XCTest
@testable import DVAIBridge

@MainActor
final class ReactiveStateTests: XCTestCase {
    func testInitialState() {
        let s = DVAIBridgeReactiveState()
        XCTAssertFalse(s.isReady)
        XCTAssertNil(s.baseUrl)
        XCTAssertNil(s.port)
        XCTAssertNil(s.currentBackend)
        XCTAssertNil(s.lastProgress)
    }

    func testDidStartUpdatesObservableProperties() {
        let s = DVAIBridgeReactiveState()
        s.didStart(BoundServer(
            baseUrl: "http://127.0.0.1:38883/v1",
            port: 38883,
            backend: .llama,
            modelId: "x"
        ))
        XCTAssertTrue(s.isReady)
        XCTAssertEqual(s.baseUrl, "http://127.0.0.1:38883/v1")
        XCTAssertEqual(s.port, 38883)
        XCTAssertEqual(s.currentBackend, .llama)
    }

    func testDidStopResetsObservableProperties() {
        let s = DVAIBridgeReactiveState()
        s.didStart(BoundServer(baseUrl: "x", port: 1, backend: .llama, modelId: "x"))
        s.didStop()
        XCTAssertFalse(s.isReady)
        XCTAssertNil(s.baseUrl)
        XCTAssertNil(s.port)
        XCTAssertNil(s.currentBackend)
    }

    func testDidReceiveProgressStoresLastEvent() {
        let s = DVAIBridgeReactiveState()
        let event = ProgressEvent(phase: .download, bytesReceived: 100)
        s.didReceiveProgress(event)
        XCTAssertEqual(s.lastProgress, event)
    }
}
