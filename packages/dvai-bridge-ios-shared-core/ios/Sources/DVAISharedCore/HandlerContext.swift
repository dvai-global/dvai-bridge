import Foundation

public struct HandlerContext: Sendable {
    public let modelId: String
    public let backendName: String

    public init(modelId: String, backendName: String) {
        self.modelId = modelId
        self.backendName = backendName
    }
}

public enum HandlerResponse {
    case json(Int, Any)
    case sse(AsyncStream<String>)
    case error(Int, String)
}

public protocol DVAIHandlers: Sendable {
    func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse
    func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse
    func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse
    func handleModels(ctx: HandlerContext) async throws -> HandlerResponse
}

/// HTTP method enum used by the framework-neutral request abstraction
/// below. We could use Foundation's `URLRequest.HTTPMethod` strings, but
/// a closed enum makes the dispatch switch in `dispatchRoute` exhaustive.
public enum DVAIHttpMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case options = "OPTIONS"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
    case head = "HEAD"

    /// Decode any verb string into a method. Defaults to `.get` for
    /// unknown verbs (the dispatcher then falls through to its
    /// 404-with-CORS path).
    public static func from(_ raw: String) -> DVAIHttpMethod {
        DVAIHttpMethod(rawValue: raw.uppercased()) ?? .get
    }
}

/// Framework-neutral request shape consumed by `dispatchRoute`. The
/// `HttpServer` actor (Hummingbird-backed) translates incoming
/// transport requests into this shape, so `dispatchRoute` and the
/// `DVAIHandlers` protocol stay independent of any specific HTTP
/// server framework. Tests construct these directly without spinning
/// up a server.
public struct DVAIRequest: Sendable {
    public let method: DVAIHttpMethod
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(
        method: DVAIHttpMethod,
        path: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup. The headers map is preserved
    /// as the original casing the transport delivered, so direct
    /// `headers["Origin"]` lookups still work for callers that know
    /// the canonical case.
    public func header(_ name: String) -> String? {
        if let v = headers[name] { return v }
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower { return v }
        return nil
    }
}

/// Framework-neutral response shape returned by `dispatchRoute`. The
/// `HttpServer` translates this back into the transport's response
/// type. Two flavors:
///
///  - `.buffered(...)` — body is fully materialised in memory; used
///    for JSON, errors, and CORS preflights.
///  - `.streaming(...)` — body is an `AsyncStream<String>` that the
///    transport flushes incrementally. Used for SSE chat-completion
///    streams. The transport is expected to write each chunk to the
///    consumer as it arrives.
public enum DVAIResponse: @unchecked Sendable {
    case buffered(status: Int, headers: [String: String], body: Data)
    case streaming(status: Int, headers: [String: String], stream: AsyncStream<String>)

    /// Convenience for tests + buffered consumers.
    public var status: Int {
        switch self {
        case .buffered(let s, _, _): return s
        case .streaming(let s, _, _): return s
        }
    }

    /// Convenience for tests + buffered consumers.
    public var headers: [String: String] {
        switch self {
        case .buffered(_, let h, _): return h
        case .streaming(_, let h, _): return h
        }
    }

    /// Buffered body if the response is buffered; empty `Data` otherwise.
    /// (Test ergonomics — streaming responses don't expose a synchronous
    /// body, callers must consume the stream.)
    public var body: Data {
        switch self {
        case .buffered(_, _, let b): return b
        case .streaming: return Data()
        }
    }
}
