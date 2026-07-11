import XCTest
@testable import DVAICapacitorLiteRTLM

final class SmokeTest: XCTestCase {
    func testPackageLoads() {
        // Confirms the module imports and the bundle loads cleanly under
        // `xcodebuild test`. The real logic lives in DVAILiteRTLMCore
        // (dvai-bridge-ios-litertlm-core) and is exercised by that
        // package's own test target — Capacitor just re-exposes it.
        XCTAssertTrue(true)
    }
}
