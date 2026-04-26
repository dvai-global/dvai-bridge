import XCTest
@testable import DVAIBridge

final class BackendSelectorTests: XCTestCase {
    func testExplicitChoicePassesThrough() throws {
        for kind in [BackendKind.llama, .foundation, .coreml] {
            let resolved = try BackendSelector.resolve(kind, config: DVAIBridgeConfig())
            XCTAssertEqual(resolved, kind)
        }
    }

    func testAutoWithGGUFResolvesToLlama() throws {
        let cfg = DVAIBridgeConfig(modelPath: "/path/to/model.gguf")
        XCTAssertEqual(try BackendSelector.resolve(.auto, config: cfg), .llama)
    }

    func testAutoWithMlmodelcResolvesToCoreML() throws {
        let cfg = DVAIBridgeConfig(modelPath: "/path/to/model.mlmodelc")
        XCTAssertEqual(try BackendSelector.resolve(.auto, config: cfg), .coreml)
    }

    func testAutoWithMlpackageResolvesToCoreML() throws {
        let cfg = DVAIBridgeConfig(modelPath: "/path/to/model.mlpackage")
        XCTAssertEqual(try BackendSelector.resolve(.auto, config: cfg), .coreml)
    }

    func testAutoWithTaskFileThrows() {
        let cfg = DVAIBridgeConfig(modelPath: "/path/to/model.task")
        XCTAssertThrowsError(try BackendSelector.resolve(.auto, config: cfg)) { err in
            guard case let DVAIBridgeError.configurationInvalid(reason) = err else {
                return XCTFail("wrong error type")
            }
            XCTAssertTrue(reason.contains("Android"))
        }
    }

    func testAutoWithUnknownExtensionThrows() {
        let cfg = DVAIBridgeConfig(modelPath: "/path/to/something.unknown")
        XCTAssertThrowsError(try BackendSelector.resolve(.auto, config: cfg))
    }

    func testAutoWithNoModelPathOnIOS26ResolvesToFoundation() throws {
        // This test only meaningfully runs on iOS 26+. On older simulators
        // the no-modelPath branch throws. Both outcomes are well-defined;
        // assert the right one based on availability.
        let cfg = DVAIBridgeConfig(modelPath: nil)
        if #available(iOS 26.0, macOS 26.0, *) {
            XCTAssertEqual(try BackendSelector.resolve(.auto, config: cfg), .foundation)
        } else {
            XCTAssertThrowsError(try BackendSelector.resolve(.auto, config: cfg))
        }
    }
}
