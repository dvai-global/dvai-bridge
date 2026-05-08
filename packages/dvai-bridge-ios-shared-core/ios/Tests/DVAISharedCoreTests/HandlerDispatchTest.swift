import XCTest
@testable import DVAISharedCore

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
        let req = DVAIRequest(method: .options, path: "/v1/chat/completions")
        let resp = await dispatchRoute(
            request: req,
            handlers: FakeHandlers(),
            ctx: ctx,
            corsConfig: .wildcard
        )
        XCTAssertEqual(resp.status, 204)
        XCTAssertEqual(resp.headers["Access-Control-Allow-Private-Network"], "true")
        XCTAssertEqual(resp.headers["Access-Control-Allow-Origin"], "*")
        XCTAssertNotNil(resp.headers["Access-Control-Allow-Methods"])
    }

    func testUnknownPathReturns404() async {
        let req = DVAIRequest(method: .get, path: "/v1/unknown")
        let resp = await dispatchRoute(
            request: req,
            handlers: FakeHandlers(),
            ctx: ctx,
            corsConfig: .wildcard
        )
        XCTAssertEqual(resp.status, 404)
    }

    func testGetModelsReturnsCannedResponse() async throws {
        let req = DVAIRequest(method: .get, path: "/v1/models")
        let resp = await dispatchRoute(
            request: req,
            handlers: FakeHandlers(),
            ctx: ctx,
            corsConfig: .wildcard
        )
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.headers["Content-Type"], "application/json")

        let json = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        XCTAssertEqual(json?["object"] as? String, "list")
    }

    func testPostChatCompletionRoutes() async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["messages": [["role": "user", "content": "hi"]]]
        )
        let req = DVAIRequest(
            method: .post,
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let resp = await dispatchRoute(
            request: req,
            handlers: FakeHandlers(),
            ctx: ctx,
            corsConfig: .wildcard
        )
        XCTAssertEqual(resp.status, 200)

        let json = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        XCTAssertEqual(json?["id"] as? String, "chatcmpl-fake")
    }

    func testCorsAllowlistMatchesOrigin() async {
        let req = DVAIRequest(
            method: .get,
            path: "/v1/models",
            headers: ["Origin": "https://app.example.com"]
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
        let req = DVAIRequest(
            method: .get,
            path: "/v1/models",
            headers: ["Origin": "https://evil.example.com"]
        )
        let resp = await dispatchRoute(
            request: req,
            handlers: FakeHandlers(),
            ctx: ctx,
            corsConfig: .allowlist(["https://app.example.com"])
        )
        // Allow-Origin header should be missing entirely (browser will block).
        XCTAssertNil(resp.headers["Access-Control-Allow-Origin"])
    }

    func testStreamingResponseRoundTrips() async throws {
        // SSE handlers return AsyncStream<String>; dispatchRoute should
        // return .streaming so the transport flushes chunks live.
        final class StreamingHandlers: DVAIHandlers, @unchecked Sendable {
            func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
                let (stream, cont) = AsyncStream<String>.makeStream()
                Task {
                    cont.yield("data: chunk1\n\n")
                    cont.yield("data: chunk2\n\n")
                    cont.yield("data: [DONE]\n\n")
                    cont.finish()
                }
                return .sse(stream)
            }
            func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse { .json(200, [:]) }
            func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse { .json(200, [:]) }
            func handleModels(ctx: HandlerContext) async throws -> HandlerResponse { .json(200, [:]) }
        }

        let req = DVAIRequest(method: .post, path: "/v1/chat/completions")
        let resp = await dispatchRoute(
            request: req,
            handlers: StreamingHandlers(),
            ctx: ctx,
            corsConfig: .wildcard
        )

        guard case .streaming(let status, let headers, let stream) = resp else {
            XCTFail("expected .streaming response, got \(resp)")
            return
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(headers["Content-Type"], "text/event-stream")
        XCTAssertEqual(headers["Cache-Control"], "no-cache")

        var collected = ""
        for await chunk in stream { collected += chunk }
        XCTAssertTrue(collected.contains("chunk1"))
        XCTAssertTrue(collected.contains("chunk2"))
        XCTAssertTrue(collected.contains("[DONE]"))
    }
}
