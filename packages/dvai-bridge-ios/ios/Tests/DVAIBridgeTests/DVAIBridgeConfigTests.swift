import XCTest
@testable import DVAIBridge

final class DVAIBridgeConfigTests: XCTestCase {
    func testDefaultsMatchSpec() {
        let c = DVAIBridgeConfig()
        XCTAssertEqual(c.backend, .auto)
        XCTAssertNil(c.modelPath)
        XCTAssertEqual(c.gpuLayers, 99)
        XCTAssertEqual(c.contextSize, 2048)
        XCTAssertEqual(c.threads, 4)
        XCTAssertFalse(c.embeddingMode)
        XCTAssertEqual(c.httpBasePort, 38883)
        XCTAssertEqual(c.httpMaxPortAttempts, 16)
        XCTAssertFalse(c.autoUnloadOnLowMemory)
        XCTAssertEqual(c.logLevel, "info")
    }

    func testToCoreOptsWildcardCors() {
        let c = DVAIBridgeConfig(modelPath: "/x.gguf")
        let opts = c.toCoreOpts()
        XCTAssertEqual(opts["modelPath"] as? String, "/x.gguf")
        XCTAssertEqual(opts["corsOrigin"] as? String, "*")
    }

    func testToCoreOptsExactCors() {
        let c = DVAIBridgeConfig(corsOrigin: .exact("https://example.com"))
        XCTAssertEqual(c.toCoreOpts()["corsOrigin"] as? String, "https://example.com")
    }

    func testToCoreOptsAllowlistCors() {
        let c = DVAIBridgeConfig(corsOrigin: .allowlist(["https://a.com", "https://b.com"]))
        XCTAssertEqual(c.toCoreOpts()["corsOrigin"] as? [String], ["https://a.com", "https://b.com"])
    }

    func testBoundServerInitFromCoreResult() throws {
        let result: [String: Any] = [
            "baseUrl": "http://127.0.0.1:38883/v1",
            "port": 38883,
            "modelId": "test-model"
        ]
        let server = try BoundServer(coreResult: result, backend: .llama)
        XCTAssertEqual(server.baseUrl, "http://127.0.0.1:38883/v1")
        XCTAssertEqual(server.port, 38883)
        XCTAssertEqual(server.backend, .llama)
        XCTAssertEqual(server.modelId, "test-model")
    }

    func testBoundServerInitMalformedResult() {
        XCTAssertThrowsError(try BoundServer(coreResult: ["baseUrl": "x"], backend: .llama))
    }
}
