import XCTest
import CryptoKit
@testable import DVAICapacitorLlama

final class ModelDownloaderTest: XCTestCase {
    /// Per-test cache dir so tests don't pollute the real App Support folder.
    private var tmpCacheDir: URL!
    private var downloader: ModelDownloader!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
        tmpCacheDir = base.appendingPathComponent("dvai-modeldownloader-test-\(UUID().uuidString)")
        downloader = ModelDownloader(cacheDirOverride: tmpCacheDir)
    }

    override func tearDown() {
        if let dir = tmpCacheDir {
            try? FileManager.default.removeItem(at: dir)
        }
        downloader = nil
        tmpCacheDir = nil
        super.tearDown()
    }

    /// Calling `cacheDirURL()` should create the directory if missing and
    /// return a path that resolves under the override.
    func testCacheDirCreates() async throws {
        let url = try await downloader.cacheDirURL()
        XCTAssertEqual(url.path, tmpCacheDir.path)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    /// Cache hit: writing a known file with a known sha256 to the cache dir
    /// then calling `downloadModel(...)` with that sha must return
    /// `cached: true` without ever touching the network — proven by passing
    /// a deliberately broken URL.
    func testCacheHitReturnsCached() async throws {
        let dir = try await downloader.cacheDirURL()
        let filename = "fixture.bin"
        let payload = "hello, dvai cache!".data(using: .utf8)!
        try payload.write(to: dir.appendingPathComponent(filename))

        let digest = SHA256.hash(data: payload)
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        // URL is intentionally bogus — a real network call would fail. The
        // cache-hit fast path bypasses network entirely.
        let bogusURL = URL(string: "https://invalid.dvai.test/should-not-fetch.bin")!
        let result = try await downloader.downloadModel(
            url: bogusURL,
            expectedSha256: hex,
            destFilename: filename,
            headers: [:],
            onProgress: { _, _ in }
        )
        XCTAssertTrue(result.cached, "expected cache-hit short-circuit")
        XCTAssertEqual(result.path, dir.appendingPathComponent(filename).path)
    }

    /// `listCachedModels()` enumerates regular files (skipping `.partial`
    /// and dotfiles) and `deleteCachedModel(...)` removes them.
    func testListAndDelete() async throws {
        let dir = try await downloader.cacheDirURL()
        let a = "alpha".data(using: .utf8)!
        let b = "bravo".data(using: .utf8)!
        try a.write(to: dir.appendingPathComponent("a.gguf"))
        try b.write(to: dir.appendingPathComponent("b.gguf"))
        // Files that must be ignored:
        try Data().write(to: dir.appendingPathComponent("c.gguf.partial"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))

        let listed = try await downloader.listCachedModels()
        let names = Set(listed.map { $0.filename })
        XCTAssertEqual(names, ["a.gguf", "b.gguf"])
        XCTAssertEqual(listed.count, 2)
        // Bytes + sha255 are populated.
        for info in listed {
            XCTAssertGreaterThan(info.bytes, 0)
            XCTAssertEqual(info.sha256.count, 64)
        }

        try await downloader.deleteCachedModel(filename: "a.gguf")
        let listed2 = try await downloader.listCachedModels()
        XCTAssertEqual(Set(listed2.map { $0.filename }), ["b.gguf"])
    }
}
