import Foundation

/// Errors thrown by `ImageDecoder.resolve(url:)` when the input URL string
/// can't be turned into image bytes.
enum ImageSourceError: Error {
    case malformedDataURL(String)
    case invalidScheme(String)
    case httpError(status: Int)
    case base64DecodeFailed
}

/// Resolves any of the three image URL schemes accepted by the DVAI bridge
/// (`data:`, `https:`/`http:`, `file:`) into the raw encoded image bytes
/// (PNG/JPEG/etc.). The bytes are returned as-is — actual format decoding
/// is performed downstream by `mtmd_helper_eval` inside llama.cpp.
struct ImageDecoder {
    /// Resolve any supported URL scheme into raw image bytes.
    ///
    /// - `data:` URLs are parsed for an optional `;base64` token and
    ///   decoded accordingly (URL-encoded payloads are also supported).
    /// - `https:` / `http:` URLs are fetched via `URLSession` with a 30s
    ///   timeout; non-2xx responses throw `httpError`.
    /// - `file:` URLs are read off disk via `Data(contentsOf:)`.
    /// - Any other scheme throws `invalidScheme`.
    static func resolve(url: String) async throws -> Data {
        if url.hasPrefix("data:") {
            return try resolveDataURL(url)
        }
        guard let parsed = URL(string: url) else {
            throw ImageSourceError.invalidScheme(url)
        }
        switch parsed.scheme?.lowercased() {
        case "https", "http":
            return try await resolveHTTP(parsed)
        case "file":
            return try Data(contentsOf: parsed)
        case let other?:
            throw ImageSourceError.invalidScheme(other)
        case nil:
            throw ImageSourceError.invalidScheme(url)
        }
    }

    /// Parse a `data:[<mediatype>][;base64],<payload>` URL into raw bytes.
    /// Strict: a missing comma is treated as malformed (we don't try to
    /// guess intent).
    private static func resolveDataURL(_ url: String) throws -> Data {
        guard let commaIdx = url.firstIndex(of: ",") else {
            throw ImageSourceError.malformedDataURL(url)
        }
        // Skip the leading "data:" (5 chars) and isolate the header / body.
        let prefixEnd = url.index(url.startIndex, offsetBy: 5)
        let header = url[prefixEnd..<commaIdx]
        let body = String(url[url.index(after: commaIdx)...])
        if header.contains(";base64") {
            guard let decoded = Data(base64Encoded: body) else {
                throw ImageSourceError.base64DecodeFailed
            }
            return decoded
        }
        // Non-base64: payload is percent-encoded text per RFC 2397.
        let decodedString = body.removingPercentEncoding ?? body
        return Data(decodedString.utf8)
    }

    /// Fetch over HTTP(S) with a 30-second timeout. Uses the older
    /// dataTask + continuation pattern so we still work on iOS 14
    /// (the package's deployment target); `URLSession.data(for:)` is
    /// iOS 15+.
    private static func resolveHTTP(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    continuation.resume(throwing: ImageSourceError.httpError(status: http.statusCode))
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
            task.resume()
        }
    }
}
