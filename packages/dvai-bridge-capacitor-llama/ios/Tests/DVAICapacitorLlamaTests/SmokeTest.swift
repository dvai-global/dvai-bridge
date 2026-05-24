import XCTest
@testable import DVAILlamaCore
// HandlerContext lives in DVAISharedCore (the Phase 3D split moved it
// out of the per-backend cores into the shared module). Match the fix
// applied to the sibling capacitor-foundation SmokeTest.swift in
// commit 62b3397 — missed for capacitor-llama in that sweep.
import DVAISharedCore

final class SmokeTest: XCTestCase {
    func testHandlerContextInit() {
        let ctx = HandlerContext(modelId: "test", backendName: "llama")
        XCTAssertEqual(ctx.modelId, "test")
        XCTAssertEqual(ctx.backendName, "llama")
    }
}
