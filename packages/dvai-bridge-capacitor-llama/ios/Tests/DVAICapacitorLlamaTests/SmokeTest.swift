import XCTest
@testable import DVAILlamaCore

final class SmokeTest: XCTestCase {
    func testHandlerContextInit() {
        let ctx = HandlerContext(modelId: "test", backendName: "llama")
        XCTAssertEqual(ctx.modelId, "test")
        XCTAssertEqual(ctx.backendName, "llama")
    }
}
