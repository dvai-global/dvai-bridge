import XCTest
import Combine
@testable import DVAIBridge

final class ProgressBroadcasterTests: XCTestCase {
    func testCombineSubscriberReceivesEvents() {
        let bcast = ProgressBroadcaster()
        let exp = expectation(description: "received event")
        let cancellable = bcast.publisher.sink { event in
            XCTAssertEqual(event.phase, .ready)
            exp.fulfill()
        }
        bcast.emit(ProgressEvent(phase: .ready))
        wait(for: [exp], timeout: 1)
        cancellable.cancel()
    }

    func testAsyncStreamReceivesEvents() async {
        let bcast = ProgressBroadcaster()
        let stream = bcast.makeStream()
        let task = Task { () -> ProgressEvent? in
            for await event in stream { return event }
            return nil
        }
        bcast.emit(ProgressEvent(phase: .download, bytesReceived: 100))
        let received = await task.value
        XCTAssertEqual(received?.phase, .download)
        XCTAssertEqual(received?.bytesReceived, 100)
    }

    func testCallbackReceivesEventsUntilCancelled() {
        let bcast = ProgressBroadcaster()
        var received: [ProgressEvent.Phase] = []
        let token = bcast.addCallback { received.append($0.phase) }

        bcast.emit(ProgressEvent(phase: .download))
        bcast.emit(ProgressEvent(phase: .ready))
        token.cancel()
        bcast.emit(ProgressEvent(phase: .error, message: "should not see"))

        XCTAssertEqual(received, [.download, .ready])
    }

    func testAllThreeSurfacesObserveSameEvent() async {
        let bcast = ProgressBroadcaster()
        var combineCount = 0
        var streamCount = 0
        var callbackCount = 0

        let cancellable = bcast.publisher.sink { _ in combineCount += 1 }
        let stream = bcast.makeStream()
        let task = Task {
            for await _ in stream { streamCount += 1; if streamCount >= 1 { break } }
        }
        let token = bcast.addCallback { _ in callbackCount += 1 }

        bcast.emit(ProgressEvent(phase: .ready))

        // Wait for AsyncStream to yield
        _ = await task.value

        XCTAssertEqual(combineCount, 1)
        XCTAssertEqual(streamCount, 1)
        XCTAssertEqual(callbackCount, 1)

        cancellable.cancel()
        token.cancel()
    }
}
