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
        XCTAssertThrowsError(
            try bridge.loadModel(
                atPath: "",
                mmprojPath: nil,
                gpuLayers: 99,
                contextSize: 2048,
                threads: 4,
                embeddingMode: false
            )
        )
        XCTAssertFalse(bridge.isLoaded)
    }

    func testLoadStubAndUnload() throws {
        let bridge = LlamaCppBridge()
        try bridge.loadModel(
            atPath: "/tmp/fake.gguf",
            mmprojPath: nil,
            gpuLayers: 99,
            contextSize: 2048,
            threads: 4,
            embeddingMode: false
        )
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
