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
