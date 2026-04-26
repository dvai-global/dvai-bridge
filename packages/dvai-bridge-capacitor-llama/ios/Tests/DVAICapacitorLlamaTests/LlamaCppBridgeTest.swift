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
        let prefix = "llama.cpp "
        XCTAssertTrue(
            version.hasPrefix(prefix),
            "expected versionString to start with '\(prefix)', got: \(version)"
        )
        XCTAssertGreaterThan(
            version.count,
            prefix.count,
            "expected versionString to include system info after prefix, got: \(version)"
        )
    }

    // MARK: - Multimodal stubs (Phase 2A Pass 1)

    func testInitiallyMmprojNotLoaded() {
        let bridge = LlamaCppBridge()
        XCTAssertFalse(bridge.isMmprojLoaded)
    }

    func testLoadMmprojRequiresMainModel() {
        let bridge = LlamaCppBridge()
        // Main model never loaded -> should fail with code 31.
        XCTAssertThrowsError(try bridge.loadMmproj(atPath: "/tmp/fake-mmproj.gguf"))
        XCTAssertFalse(bridge.isMmprojLoaded)
    }

    func testEmptyMmprojPathFails() {
        let bridge = LlamaCppBridge()
        XCTAssertThrowsError(try bridge.loadMmproj(atPath: ""))
        XCTAssertFalse(bridge.isMmprojLoaded)
    }

    func testUnloadMmprojIsIdempotent() {
        let bridge = LlamaCppBridge()
        // Repeated unload calls on a never-loaded bridge must not crash.
        bridge.unloadMmproj()
        bridge.unloadMmproj()
        XCTAssertFalse(bridge.isMmprojLoaded)
    }
}
