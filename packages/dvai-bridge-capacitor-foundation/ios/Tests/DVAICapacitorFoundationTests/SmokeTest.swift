import XCTest
@testable import DVAIFoundationCore
// HandlerContext lives in DVAISharedCore (see packages/dvai-bridge-ios-shared-core/
// ios/Sources/DVAISharedCore/HandlerContext.swift) and is re-exported via
// the iOS umbrella's transitive graph at consumer-build time. The test
// target needs an explicit import to see it locally.
import DVAISharedCore

final class SmokeTest: XCTestCase {
    func testHandlerContextInit() {
        let ctx = HandlerContext(modelId: "test", backendName: "foundation")
        XCTAssertEqual(ctx.modelId, "test")
        XCTAssertEqual(ctx.backendName, "foundation")
    }
}
