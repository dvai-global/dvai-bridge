import XCTest
@testable import DVAICapacitorMediaPipe

final class SmokeTest: XCTestCase {
    func testPackageLoads() {
        // The iOS plugin is a stub — this just confirms the module imports
        // and the bundle loads cleanly under `xcodebuild test`.
        XCTAssertTrue(true)
    }
}
