import XCTest
@testable import DVAICapacitorLlama
import DVAICapacitorLlamaObjC

final class LlamaCppBridgeTest: XCTestCase {
    func testInitiallyNotLoaded() {
        let bridge = LlamaCppBridge()
        XCTAssertFalse(bridge.isLoaded)
        XCTAssertNil(bridge.currentModelPath)
    }

    func testLoadEmptyPathFails() {
        let bridge = LlamaCppBridge()
        var error: NSError? = nil
        let ok = bridge.loadModel(
            atPath: "",
            mmprojPath: nil,
            gpuLayers: 99,
            contextSize: 2048,
            threads: 4,
            embeddingMode: false,
            error: &error
        )
        XCTAssertFalse(ok)
        XCTAssertNotNil(error)
    }

    func testLoadStubAndUnload() {
        let bridge = LlamaCppBridge()
        var error: NSError? = nil
        let ok = bridge.loadModel(
            atPath: "/tmp/fake.gguf",
            mmprojPath: nil,
            gpuLayers: 99,
            contextSize: 2048,
            threads: 4,
            embeddingMode: false,
            error: &error
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(bridge.isLoaded)
        XCTAssertEqual(bridge.currentModelPath, "/tmp/fake.gguf")
        bridge.unload()
        XCTAssertFalse(bridge.isLoaded)
    }

    func testVersionStringReturnsStub() {
        let bridge = LlamaCppBridge()
        XCTAssertEqual(bridge.versionString(), "llama.cpp-stub-0.1")
    }
}
