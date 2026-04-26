import XCTest
@testable import DVAILlamaCore

final class HttpServerTest: XCTestCase {
    func testTryBindBindsBasePort() async throws {
        let server = HttpServer()
        let port = try await server.tryBind(basePort: 39001, maxAttempts: 4, host: "127.0.0.1")
        XCTAssertEqual(port, 39001)
        await server.stop()
    }

    func testTryBindFallsBackOnPortInUse() async throws {
        // Block port 39010 with another server
        let blocker = HttpServer()
        _ = try await blocker.tryBind(basePort: 39010, maxAttempts: 1, host: "127.0.0.1")

        let server = HttpServer()
        let port = try await server.tryBind(basePort: 39010, maxAttempts: 4, host: "127.0.0.1")
        XCTAssertEqual(port, 39011)
        await server.stop()
        await blocker.stop()
    }

    func testStopIsIdempotent() async throws {
        let server = HttpServer()
        await server.stop() // before start — should not throw
        _ = try await server.tryBind(basePort: 39020, maxAttempts: 1, host: "127.0.0.1")
        await server.stop()
        await server.stop() // double-stop should not throw
    }

    func testThrowsActionableErrorWhenAllPortsBlocked() async throws {
        // Block 39030..39032
        var blockers: [HttpServer] = []
        for i in 0..<3 {
            let s = HttpServer()
            _ = try await s.tryBind(basePort: 39030 + i, maxAttempts: 1, host: "127.0.0.1")
            blockers.append(s)
        }
        defer {
            Task { for b in blockers { await b.stop() } }
        }

        let server = HttpServer()
        do {
            _ = try await server.tryBind(basePort: 39030, maxAttempts: 3, host: "127.0.0.1")
            XCTFail("should have thrown")
        } catch let error as NSError {
            XCTAssertTrue(error.localizedDescription.contains("39030..39032"),
                          "Error should name the tried range; got: \(error.localizedDescription)")
        }
    }
}
