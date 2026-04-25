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

    func testLoadFakePathFails() {
        let bridge = LlamaCppBridge()
        XCTAssertThrowsError(
            try bridge.loadModel(
                atPath: "/tmp/definitely-does-not-exist.gguf",
                mmprojPath: nil,
                gpuLayers: 99,
                contextSize: 2048,
                threads: 4,
                embeddingMode: false
            )
        )
        XCTAssertFalse(bridge.isLoaded)
        XCTAssertNil(bridge.currentModelPath)
    }

    func testVersionStringContainsLlama() {
        let bridge = LlamaCppBridge()
        let version = bridge.versionString()
        XCTAssertTrue(
            version.contains("llama.cpp"),
            "expected versionString to contain 'llama.cpp', got: \(version)"
        )
    }
}
