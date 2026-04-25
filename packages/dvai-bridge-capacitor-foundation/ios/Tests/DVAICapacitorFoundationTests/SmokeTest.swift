import XCTest
@testable import DVAICapacitorFoundation

final class SmokeTest: XCTestCase {
    func testHandlerContextInit() {
        let ctx = HandlerContext(modelId: "test", backendName: "foundation")
        XCTAssertEqual(ctx.modelId, "test")
        XCTAssertEqual(ctx.backendName, "foundation")
    }
}
