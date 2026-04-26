import XCTest
@testable import DVAICoreMLCore

@available(iOS 18.0, macOS 15.0, *)
final class CoreMLEngineTests: XCTestCase {
    func testLoadFailsForMissingFile() {
        let bogusURL = URL(fileURLWithPath: "/tmp/definitely-does-not-exist.mlmodelc")
        XCTAssertThrowsError(try CoreMLEngine(modelURL: bogusURL, eosTokenId: 0)) { err in
            guard case let CoreMLBackendError.modelLoadFailed(reason) = err else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertTrue(
                reason.contains("error") || reason.contains("Error") || reason.contains("file"),
                "reason should mention error details, got: \(reason)"
            )
        }
    }
}
