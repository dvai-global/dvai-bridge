import XCTest
@testable import DVAIBridge

final class ProgressEventTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let original = ProgressEvent(
            phase: .download,
            bytesReceived: 1024,
            bytesTotal: 4096,
            percent: 25.0,
            message: nil
        )
        let json = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProgressEvent.self, from: json)
        XCTAssertEqual(original, decoded)
    }

    func testPhaseRawValues() {
        XCTAssertEqual(ProgressEvent.Phase.download.rawValue, "download")
        XCTAssertEqual(ProgressEvent.Phase.verify.rawValue, "verify")
        XCTAssertEqual(ProgressEvent.Phase.load.rawValue, "load")
        XCTAssertEqual(ProgressEvent.Phase.ready.rawValue, "ready")
        XCTAssertEqual(ProgressEvent.Phase.error.rawValue, "error")
    }
}
