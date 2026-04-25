import XCTest
@testable import DVAICapacitorLlama

final class ImageDecoderTest: XCTestCase {
    /// `data:image/png;base64,...` round-trips to bytes whose first 8 bytes
    /// are the canonical PNG magic header.
    func testDataURLBase64() async throws {
        let url = try String(contentsOf: imageFixtureURL("tiny-test-base64.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = try await ImageDecoder.resolve(url: url)
        XCTAssertEqual(
            Array(bytes.prefix(8)),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "expected PNG magic header"
        )
    }

    /// `file://` URLs return the raw bytes off disk.
    func testFileURL() async throws {
        let pngURL = imageFixtureURL("tiny-test.png")
        let result = try await ImageDecoder.resolve(url: pngURL.absoluteString)
        let raw = try Data(contentsOf: pngURL)
        XCTAssertEqual(result, raw)
    }

    /// Unsupported schemes throw `invalidScheme`.
    func testInvalidScheme() async {
        do {
            _ = try await ImageDecoder.resolve(url: "ftp://example.com/x.png")
            XCTFail("Expected throw")
        } catch ImageSourceError.invalidScheme {
            // expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// `data:` URL with no comma → `malformedDataURL`.
    func testMalformedDataURL() async {
        do {
            _ = try await ImageDecoder.resolve(url: "data:image/png;base64")
            XCTFail("Expected throw")
        } catch ImageSourceError.malformedDataURL {
            // expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// `https://` URL fetches response body bytes verbatim. Mocked at the
    /// URLSession layer via `URLProtocol.registerClass` so no real network
    /// is touched.
    func testHTTPSFetchesBytes() async throws {
        let payload = try Data(contentsOf: imageFixtureURL("tiny-test.png"))
        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockURLProtocol.self)
            MockURLProtocol.handler = nil
        }
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, payload)
        }

        let bytes = try await ImageDecoder.resolve(url: "https://example.invalid/img.png")
        XCTAssertEqual(bytes, payload)
    }

    /// HTTP non-2xx → `ImageSourceError.httpError(status:)` carrying the code.
    func testHTTPErrorThrowsHttpError() async {
        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockURLProtocol.self)
            MockURLProtocol.handler = nil
        }
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await ImageDecoder.resolve(url: "https://example.invalid/missing.png")
            XCTFail("Expected throw")
        } catch ImageSourceError.httpError(let status) {
            XCTAssertEqual(status, 404)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// Walks up from this test source file until it finds the repo-root
    /// `fixtures/` directory — same pattern as `AudioDecoderTest`.
    private func imageFixtureURL(_ name: String) -> URL {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("fixtures").path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path {
                fatalError("fixtures dir not found walking up from \(#file)")
            }
            dir = parent
        }
        return dir.appendingPathComponent("fixtures").appendingPathComponent("images").appendingPathComponent(name)
    }
}

/// In-process `URLProtocol` stub that intercepts every URLSession request
/// and dispatches it to a per-test handler. Registered globally via
/// `URLProtocol.registerClass`, which `URLSession.shared` consults — so the
/// production code under test (which uses `URLSession.shared`) is exercised
/// without any actual network I/O.
private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
