// Internal/ModelDownloader.swift
import Foundation
import CryptoKit

/// Result of `listCachedModels()` — one entry per file in the cache dir.
public struct CachedModelInfoSwift: Sendable {
    public let filename: String
    public let path: String
    public let bytes: Int64
    public let sha256: String
}

/// Resumable, sha256-verified model downloader plus cache management.
///
/// Cache directory layout (per spec §9.2):
///   - default: `<App Support>/<bundle-id>/dvai-models/<filename>`
///   - test override: any caller-supplied URL (used by unit tests to keep
///     real App Support clean).
///
/// Concurrency: an `actor` so cache-list / cache-delete operations are
/// serialised. The download path delegates to a private `URLSessionDataDelegate`
/// (compatible with iOS 14+, unlike the iOS-15 `bytes(for:)` API).
actor ModelDownloader {
    enum DownloadError: LocalizedError {
        case checksumMismatch(expected: String, got: String)
        case httpError(status: Int)
        case missingApplicationSupport
        case sha256Required
        case ioError(String)

        var errorDescription: String? {
            switch self {
            case .checksumMismatch(let expected, let got):
                return "ChecksumMismatchError: expected \(expected), got \(got)"
            case .httpError(let status):
                return "HTTP error \(status)"
            case .missingApplicationSupport:
                return "Could not locate Application Support directory"
            case .sha256Required:
                return "sha256 is required"
            case .ioError(let msg):
                return "I/O error: \(msg)"
            }
        }
    }

    private let cacheDirOverride: URL?

    init(cacheDirOverride: URL? = nil) {
        self.cacheDirOverride = cacheDirOverride
    }

    // MARK: - Cache dir

    /// Resolve and create the cache directory. Returns the directory URL.
    func cacheDirURL() throws -> URL {
        if let override = cacheDirOverride {
            try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        guard let asd = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw DownloadError.missingApplicationSupport
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "co.deepvoiceai.dvai-bridge"
        let dir = asd.appendingPathComponent(bundleId).appendingPathComponent("dvai-models")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cacheDirPath() throws -> String {
        try cacheDirURL().path
    }

    // MARK: - List / delete

    /// Enumerate files in the cache dir (skipping `.partial` and dotfiles),
    /// sha256 each, return one entry per file.
    func listCachedModels() throws -> [CachedModelInfoSwift] {
        let dir = try cacheDirURL()
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [CachedModelInfoSwift] = []
        for name in names {
            if name.hasPrefix(".") || name.hasSuffix(".partial") { continue }
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: url.path, isDirectory: &isDir) || isDir.boolValue { continue }
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let sha = try Self.sha256OfFile(at: url)
            out.append(CachedModelInfoSwift(
                filename: name,
                path: url.path,
                bytes: bytes,
                sha256: sha
            ))
        }
        return out
    }

    func deleteCachedModel(filename: String) throws {
        let dir = try cacheDirURL()
        let url = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let partial = dir.appendingPathComponent("\(filename).partial")
        if FileManager.default.fileExists(atPath: partial.path) {
            try? FileManager.default.removeItem(at: partial)
        }
    }

    // MARK: - Download

    /// Download `url` into `<cacheDir>/<destFilename>`, resumable + sha256-verified.
    ///
    /// - Parameters:
    ///   - expectedSha256: lowercase-hex digest the final file MUST match.
    ///   - onProgress: bytesDone, optional bytesTotal. Caller already throttles
    ///     ~10/sec internally; do not throttle again here.
    /// - Returns: (final-path, cached). `cached: true` means the file was already
    ///   present with a matching hash and no network request was made.
    func downloadModel(
        url: URL,
        expectedSha256: String,
        destFilename: String,
        headers: [String: String],
        onProgress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws -> (path: String, cached: Bool) {
        guard !expectedSha256.isEmpty else { throw DownloadError.sha256Required }
        let expected = expectedSha256.lowercased()

        let dir = try cacheDirURL()
        let final = dir.appendingPathComponent(destFilename)
        let partial = dir.appendingPathComponent("\(destFilename).partial")
        let fm = FileManager.default

        // Step 2: cache hit check.
        if fm.fileExists(atPath: final.path) {
            let existing = try Self.sha256OfFile(at: final)
            if existing == expected {
                Self.applyNoBackupAttribute(final)
                return (final.path, true)
            }
            // Step 3: mismatch → delete and fall through.
            try? fm.removeItem(at: final)
        }

        // Step 4: stream download (resumable).
        try await StreamingDownload.run(
            url: url,
            partial: partial,
            headers: headers,
            onProgress: onProgress
        ).verifyAndFinalize(
            final: final,
            partial: partial,
            expectedSha256: expected
        )

        // Step 7: iOS no-backup attribute.
        Self.applyNoBackupAttribute(final)

        return (final.path, false)
    }

    // MARK: - Helpers

    /// Compute SHA-256 of a file lazily by streaming 64 KiB chunks.
    static func sha256OfFile(at url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Set `URLResourceKey.isExcludedFromBackupKey = true`. Best-effort —
    /// failure here is non-fatal (e.g. unit tests in tmp dirs).
    static func applyNoBackupAttribute(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }
}

// MARK: - Streaming download (URLSessionDataDelegate, iOS 14+)

/// Result of a streaming download: the running SHA-256 digest as hex.
struct StreamingDownloadResult {
    let gotHex: String

    /// Verify hash, atomic-rename, and clean up on mismatch.
    func verifyAndFinalize(final: URL, partial: URL, expectedSha256: String) throws {
        let fm = FileManager.default
        if gotHex != expectedSha256 {
            try? fm.removeItem(at: partial)
            try? fm.removeItem(at: final)
            throw ModelDownloader.DownloadError.checksumMismatch(
                expected: expectedSha256,
                got: gotHex
            )
        }
        if fm.fileExists(atPath: final.path) {
            try? fm.removeItem(at: final)
        }
        try fm.moveItem(at: partial, to: final)
    }
}

/// Wraps `URLSessionDataDelegate` with a continuation so the streaming
/// download can be `await`ed. Handles:
///  - Replaying existing `.partial` bytes through SHA-256 (resume).
///  - Range request + 200/206 handling (server-honoured / not-honoured).
///  - 64 KiB-buffered hashing + appending.
///  - Progress debounced to ~10/sec.
final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var hasher = SHA256()
    private var written: Int64 = 0
    private var totalBytes: Int64?
    private var writeHandle: FileHandle?
    private var lastEmit: Date = .distantPast
    private let debounceInterval: TimeInterval = 0.1

    private let partial: URL
    private let onProgress: @Sendable (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<StreamingDownloadResult, Error>?
    private var didFinish = false

    /// Whether we asked the server for a Range. If true and the server replies
    /// 200 (full body), reset hash + truncate file before consuming data.
    private var requestedRange = false
    private var serverWillSendFullBody = false

    private init(
        partial: URL,
        onProgress: @Sendable @escaping (Int64, Int64?) -> Void
    ) {
        self.partial = partial
        self.onProgress = onProgress
    }

    /// Entry point. Replays existing `.partial`, performs the download,
    /// returns the final hex digest on success.
    static func run(
        url: URL,
        partial: URL,
        headers: [String: String],
        onProgress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws -> StreamingDownloadResult {
        let runner = StreamingDownload(partial: partial, onProgress: onProgress)
        try runner.replayPartial()

        var request = URLRequest(url: url)
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if runner.written > 0 {
            request.setValue("bytes=\(runner.written)-", forHTTPHeaderField: "Range")
            runner.requestedRange = true
        }

        let session = URLSession(
            configuration: .default,
            delegate: runner,
            delegateQueue: nil  // serial OperationQueue created internally
        )
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { cont in
            runner.continuation = cont
            let task = session.dataTask(with: request)
            task.resume()
        }
    }

    /// Replay any existing .partial bytes through the hash so we can resume.
    private func replayPartial() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: partial.path) else { return }
        let attrs = try fm.attributesOfItem(atPath: partial.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 { return }
        let handle = try FileHandle(forReadingFrom: partial)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            written += Int64(chunk.count)
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(with: .failure(ModelDownloader.DownloadError.httpError(status: -1)))
            completionHandler(.cancel)
            return
        }
        if !(200...206).contains(http.statusCode) {
            finish(with: .failure(ModelDownloader.DownloadError.httpError(status: http.statusCode)))
            completionHandler(.cancel)
            return
        }

        let fm = FileManager.default

        // If we asked for a Range and got 200 → server didn't honour it,
        // restart hash + truncate file.
        if requestedRange && http.statusCode == 200 {
            hasher = SHA256()
            written = 0
            serverWillSendFullBody = true
            try? fm.removeItem(at: partial)
        }

        let contentLength = http.expectedContentLength  // -1 if unknown
        if contentLength >= 0 {
            totalBytes = written + contentLength
        }

        // Open partial for write at current offset.
        if !fm.fileExists(atPath: partial.path) {
            fm.createFile(atPath: partial.path, contents: nil)
        }
        do {
            let h = try FileHandle(forWritingTo: partial)
            try h.seek(toOffset: UInt64(written))
            writeHandle = h
        } catch {
            finish(with: .failure(error))
            completionHandler(.cancel)
            return
        }

        // Initial 0% emit so callers see we've started.
        onProgress(written, totalBytes)
        lastEmit = Date()

        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let h = writeHandle else { return }
        do {
            try h.write(contentsOf: data)
        } catch {
            finish(with: .failure(error))
            return
        }
        hasher.update(data: data)
        written += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastEmit) >= debounceInterval {
            onProgress(written, totalBytes)
            lastEmit = now
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        try? writeHandle?.close()
        writeHandle = nil
        if let error = error {
            finish(with: .failure(error))
            return
        }
        // Final progress emit.
        onProgress(written, totalBytes)
        let digest = hasher.finalize()
        let gotHex = digest.map { String(format: "%02x", $0) }.joined()
        finish(with: .success(StreamingDownloadResult(gotHex: gotHex)))
    }

    private func finish(with result: Result<StreamingDownloadResult, Error>) {
        guard !didFinish else { return }
        didFinish = true
        let cont = continuation
        continuation = nil
        cont?.resume(with: result)
    }
}
