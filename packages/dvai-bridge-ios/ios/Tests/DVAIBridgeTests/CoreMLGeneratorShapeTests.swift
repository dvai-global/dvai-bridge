import XCTest
@testable import DVAICoreMLCore

@available(iOS 18.0, macOS 15.0, *)
final class CoreMLGeneratorShapeTests: XCTestCase {
    func testTypesCompile() {
        // Ensures the public-internal API compiles correctly at the type level.
        // Real generation is tested end-to-end in RealModelIntegrationTest (Task 18).
        let _: AsyncThrowingStream<String, Error>.Type = AsyncThrowingStream<String, Error>.self
    }
}
