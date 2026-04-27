import XCTest
@testable import DVAIBridge

final class DVAIBridgeErrorTests: XCTestCase {
    func testErrorDescriptionsAreUserFacing() {
        let cases: [(DVAIBridgeError, String)] = [
            (.notStarted, "has not been started"),
            (.alreadyStarted(currentBackend: .llama, baseUrl: "http://127.0.0.1:38883/v1"), "already running"),
            (.configurationInvalid(reason: "x"), "invalid"),
            (.backendUnavailable(.foundation, reason: "iOS 26+ required"), "unavailable"),
            (.modelLoadFailed(reason: "x"), "Model load failed"),
            (.downloadFailed(reason: "x"), "Download failed"),
            (.checksumMismatch, "SHA-256"),
            (.backendError(underlying: "x"), "Backend error"),
        ]
        for (err, expectedFragment) in cases {
            XCTAssertNotNil(err.errorDescription, "error has no description: \(err)")
            XCTAssertTrue(
                err.errorDescription!.contains(expectedFragment),
                "expected '\(expectedFragment)' in '\(err.errorDescription!)'"
            )
        }
    }

    func testBackendKindAllCases() {
        XCTAssertEqual(BackendKind.allCases.count, 5)
        XCTAssertTrue(BackendKind.allCases.contains(.auto))
        XCTAssertTrue(BackendKind.allCases.contains(.llama))
        XCTAssertTrue(BackendKind.allCases.contains(.foundation))
        XCTAssertTrue(BackendKind.allCases.contains(.coreml))
        XCTAssertTrue(BackendKind.allCases.contains(.mlx))
    }
}
