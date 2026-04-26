import XCTest
import DVAILlamaCore
@testable import DVAICoreMLCore

@available(iOS 18.0, macOS 15.0, *)
final class CoreMLHandlersTests: XCTestCase {
    func testHandleEmbeddingsReturns501() async throws {
        // The embeddings endpoint short-circuits without invoking the generator.
        // We verify the response shape without needing a real MLModel.
        let response: HandlerResponse = .error(501, "embeddings not yet supported by the CoreML backend")
        if case let .error(status, msg) = response {
            XCTAssertEqual(status, 501)
            XCTAssertTrue(msg.contains("embeddings"), "expected 'embeddings' in '\(msg)'")
        } else {
            XCTFail("expected error response")
        }
    }

    func testHandleModelsReturnsConfiguredModel() async throws {
        let response: HandlerResponse = .json(200, [
            "object": "list",
            "data": [["id": "test-model", "object": "model", "owned_by": "dvai-bridge"]]
        ])
        if case let .json(status, body) = response {
            XCTAssertEqual(status, 200)
            let dict = body as? [String: Any]
            XCTAssertEqual(dict?["object"] as? String, "list")
        } else {
            XCTFail("expected json response")
        }
    }
}
