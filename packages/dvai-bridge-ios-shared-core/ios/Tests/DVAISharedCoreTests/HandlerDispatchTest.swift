import XCTest
@testable import DVAISharedCore
import Telegraph

/// A fake DVAIHandlers implementation that returns canned responses.
final class FakeHandlers: DVAIHandlers, @unchecked Sendable {
    func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(200, ["id": "chatcmpl-fake", "object": "chat.completion"])
    }
    func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(200, ["object": "text_completion"])
    }
    func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(200, ["object": "list"])
    }
    func handleModels(ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(200, ["object": "list", "data": [["id": ctx.modelId]]])
    }
}

final class HandlerDispatchTest: XCTestCase {
    let ctx = HandlerContext(modelId: "test", backendName: "llama")

    func testCorsPreflightReturns204WithPNA() async {
        let req = HTTPRequest(.OPTIONS, uri: URI(path: "/v1/chat/completions"))
        let resp = await dispatchRoute(
            request: req,
            handlers: FakeHandlers(),
            ctx: ctx,
            corsConfig: .wildcard
        )
        XCTAssertEqual(resp.status.code, 204)
        XCTAssertEqual(resp.headers["Access-Control-Allow-Private-Network"], "true")
        XCTAssertEqual(resp.headers["Access-Control-Allow-Origin"], "*")
        XCTAssertNotNil(resp.headers["Access-Control-Allow-Methods"])
    }

    func testUnknownPathReturns404() async {
        let req = HTTPRequest(.GET, uri: URI(path: "/v1/unknown"))
        let resp = await dispatchRoute(
            request: req,
            handlers: FakeHandlers(),
            ctx: ctx,
            corsConfig: .wildcard
        )
        XCTAssertEqual(resp.status.code, 404)
    }

    func testGetModelsReturnsCannedResponse() async throws {
        let req = HTTPRequest(.GET, uri: URI(path: "/v1/models"))
        let resp = await dispatchRoute(
            request: req,
            handlers: FakeHandlers(),
            ctx: ctx,
            corsConfig: .wildcard
        )
        XCTAssertEqual(resp.status.code, 200)
        XCTAssertEqual(resp.headers["Content-Type"], "application/json")

        let json = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        XCTAssertEqual(json?["object"] as? String, "list")
    }

    func testPostChatCompletionRoutes() async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["messages": [["role": "user", "content": "hi"]]]
        )
        var headers: HTTPHeaders = .empty
        headers["Content-Type"] = "application/json"
        let req = HTTPRequest(
            .POST,
            uri: URI(path: "/v1/chat/completions"),
            headers: headers,
            body: body
        )
        let resp = await dispatchRoute(
            request: req,
            handlers: FakeHandlers(),
            ctx: ctx,
            corsConfig: .wildcard
        )
        XCTAssertEqual(resp.status.code, 200)

        let json = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        XCTAssertEqual(json?["id"] as? String, "chatcmpl-fake")
    }

    func testCorsAllowlistMatchesOrigin() async {
        var headers: HTTPHeaders = .empty
        headers["Origin"] = "https://app.example.com"
        let req = HTTPRequest(
            .GET,
            uri: URI(path: "/v1/models"),
            headers: headers,
            body: Data()
        )
        let resp = await dispatchRoute(
            request: req,
            handlers: FakeHandlers(),
            ctx: ctx,
            corsConfig: .allowlist([
                "https://app.example.com",
                "https://other.example.com",
            ])
        )
        XCTAssertEqual(resp.headers["Access-Control-Allow-Origin"], "https://app.example.com")
    }

    func testCorsAllowlistRejectsUnlistedOrigin() async {
        var headers: HTTPHeaders = .empty
        headers["Origin"] = "https://evil.example.com"
        let req = HTTPRequest(
            .GET,
            uri: URI(path: "/v1/models"),
            headers: headers,
            body: Data()
        )
        let resp = await dispatchRoute(
            request: req,
            handlers: FakeHandlers(),
            ctx: ctx,
            corsConfig: .allowlist(["https://app.example.com"])
        )
        // Allow-Origin header should be missing entirely (browser will block)
        XCTAssertNil(resp.headers["Access-Control-Allow-Origin"])
    }
}
