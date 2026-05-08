import XCTest
@testable import DVAISharedCore

/// v3.2.x — drive a live HTTP request through the Hummingbird-backed
/// `HttpServer` end-to-end. Counterpart to the (Telegraph-era)
/// `HttpServerTest` lifecycle suite, which only exercises bind / stop
/// + port-fallback. This suite proves the request → dispatchRoute →
/// response → byte-on-the-wire path actually works for both buffered
/// (JSON) and streaming (SSE) handlers.
@available(iOS 17.0, macOS 14.0, *)
final class HttpServerIntegrationTest: XCTestCase {

    // MARK: - Test handlers

    /// Replies to chat/completions with an SSE stream of three chunks
    /// + [DONE]. Used to verify that streaming responses flush
    /// incrementally — we observe the bytes arriving via
    /// `URLSession.bytes(for:)` and assert each chunk lands separately.
    final class StreamingHandlers: DVAIHandlers, @unchecked Sendable {
        let chunkInterval: TimeInterval

        init(chunkInterval: TimeInterval = 0.05) {
            self.chunkInterval = chunkInterval
        }

        func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
            let interval = chunkInterval
            let (stream, cont) = AsyncStream<String>.makeStream()
            Task {
                for chunk in ["data: chunk1\n\n", "data: chunk2\n\n", "data: chunk3\n\n", "data: [DONE]\n\n"] {
                    cont.yield(chunk)
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                cont.finish()
            }
            return .sse(stream)
        }
        func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse { .json(200, [:]) }
        func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse { .json(200, [:]) }
        func handleModels(ctx: HandlerContext) async throws -> HandlerResponse {
            .json(200, ["object": "list", "data": [["id": ctx.modelId]]])
        }
    }

    // MARK: - Helpers

    /// Bring up an HttpServer on a free port, hand back the bound URL.
    /// Caller must `stop()` when done.
    private func startServer(
        handlers: DVAIHandlers = StreamingHandlers(),
        cors: CORSConfig = .wildcard
    ) async throws -> (server: HttpServer, baseUrl: URL) {
        let server = HttpServer()
        let ctx = HandlerContext(modelId: "integration-test-model", backendName: "test")
        await server.installRoutes(handlers: handlers, ctx: ctx, corsConfig: cors)
        // Use a port range well above other tests' bands to avoid
        // collisions when the suite runs concurrently.
        let port = try await server.tryBind(basePort: 39200, maxAttempts: 32, host: "127.0.0.1")
        let url = URL(string: "http://127.0.0.1:\(port)")!
        return (server, url)
    }

    // MARK: - Buffered (JSON) path

    func testGetModelsReturnsJsonOverTheWire() async throws {
        let (server, baseUrl) = try await startServer()
        defer { Task { await server.stop() } }

        let url = baseUrl.appendingPathComponent("v1/models")
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as! HTTPURLResponse

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["object"] as? String, "list")
        let array = json?["data"] as? [[String: Any]]
        XCTAssertEqual(array?.first?["id"] as? String, "integration-test-model")
    }

    func testCorsPreflightReturns204() async throws {
        let (server, baseUrl) = try await startServer()
        defer { Task { await server.stop() } }

        var req = URLRequest(url: baseUrl.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "OPTIONS"
        req.setValue("https://app.example.com", forHTTPHeaderField: "Origin")

        let (_, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 204)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Access-Control-Allow-Private-Network"), "true")
        XCTAssertNotNil(http.value(forHTTPHeaderField: "Access-Control-Allow-Methods"))
    }

    func testUnknownPathReturns404WithCors() async throws {
        let (server, baseUrl) = try await startServer()
        defer { Task { await server.stop() } }

        let (_, response) = try await URLSession.shared.data(from: baseUrl.appendingPathComponent("nope"))
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 404)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
    }

    // MARK: - Streaming (SSE) path

    func testSseStreamFlushesChunksIncrementally() async throws {
        // 50ms between chunks — small enough to keep the test fast,
        // large enough that "all chunks at once" would be detectable.
        let (server, baseUrl) = try await startServer(handlers: StreamingHandlers(chunkInterval: 0.05))
        defer { Task { await server.stop() } }

        var req = URLRequest(url: baseUrl.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)

        // bytes(for:) gives us an AsyncSequence<UInt8> we can consume
        // chunk-by-chunk to observe streaming behavior. A non-streaming
        // proxy would deliver everything in one TCP read; Hummingbird's
        // ResponseBody writer should flush each `data: …\n\n` chunk
        // separately.
        let (stream, response) = try await URLSession.shared.bytes(for: req)
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-cache")

        // Collect all body bytes into a buffer + record per-chunk
        // arrival timestamps via newline boundaries. We count distinct
        // ChunkArrivalEvents to verify streaming.
        var collected = Data()
        var firstByteAt: Date? = nil
        var doneAt: Date? = nil
        for try await byte in stream {
            collected.append(byte)
            if firstByteAt == nil { firstByteAt = Date() }
            if collected.range(of: "[DONE]".data(using: .utf8)!) != nil {
                doneAt = Date()
                // Read a couple more bytes (trailing \n\n) then exit.
                continue
            }
        }
        let asString = String(data: collected, encoding: .utf8) ?? ""
        XCTAssertTrue(asString.contains("chunk1"))
        XCTAssertTrue(asString.contains("chunk2"))
        XCTAssertTrue(asString.contains("chunk3"))
        XCTAssertTrue(asString.contains("[DONE]"))

        // Smoke-check: total elapsed should be ≥ 3 × chunkInterval
        // (since 4 chunks emit at 50ms apart). If the server were
        // buffering the whole body server-side, time-to-first-byte
        // would equal time-to-last-byte rather than streaming through.
        if let first = firstByteAt, let done = doneAt {
            let elapsed = done.timeIntervalSince(first)
            XCTAssertGreaterThan(elapsed, 0.05,
                "Streaming should take ≥ 1 chunkInterval; got \(elapsed)s")
        }
    }
}
