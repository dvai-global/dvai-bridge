// Internal/HandlerDispatch.swift
import Foundation

/// CORS configuration for the dispatch layer.
public enum CORSConfig {
    case wildcard
    case exact(String)
    case allowlist([String])

    func headerValue(forRequestOrigin reqOrigin: String?) -> String? {
        switch self {
        case .wildcard:
            return "*"
        case .exact(let s):
            return s
        case .allowlist(let list):
            guard let o = reqOrigin else { return nil }
            return list.contains(o) ? o : nil
        }
    }
}

/// Builds the standard CORS + Private Network Access header set for a
/// response.
public func corsHeaders(reqOrigin: String?, config: CORSConfig) -> [String: String] {
    var headers: [String: String] = [
        "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
        "Access-Control-Allow-Private-Network": "true",
    ]
    if let allow = config.headerValue(forRequestOrigin: reqOrigin) {
        headers["Access-Control-Allow-Origin"] = allow
    }
    return headers
}

/// Dispatches a framework-neutral `DVAIRequest` to the appropriate
/// `DVAIHandlers` method.
///
/// - Catches handler errors and converts them to 500 responses.
/// - Handles `OPTIONS` preflight (204) and unknown routes (404).
/// - Adds CORS + PNA headers to every response.
/// - Returns a `.streaming` `DVAIResponse` for SSE handlers so the
///   transport can flush chunks incrementally.
public func dispatchRoute(
    request: DVAIRequest,
    handlers: DVAIHandlers,
    ctx: HandlerContext,
    corsConfig: CORSConfig
) async -> DVAIResponse {
    let reqOrigin = request.header("Origin")
    let cors = corsHeaders(reqOrigin: reqOrigin, config: corsConfig)

    // OPTIONS preflight — respond 204 with CORS headers, no body.
    if request.method == .options {
        return .buffered(status: 204, headers: cors, body: Data())
    }

    let path = request.path
    let method = request.method

    do {
        let handlerResponse: HandlerResponse
        switch (method, path) {
        case (.post, "/v1/chat/completions"):
            let body = try parseJSONBody(request.body)
            handlerResponse = try await handlers.handleChatCompletion(body: body, ctx: ctx)
        case (.post, "/v1/completions"):
            let body = try parseJSONBody(request.body)
            handlerResponse = try await handlers.handleCompletion(body: body, ctx: ctx)
        case (.post, "/v1/embeddings"):
            let body = try parseJSONBody(request.body)
            handlerResponse = try await handlers.handleEmbeddings(body: body, ctx: ctx)
        case (.get, "/v1/models"):
            handlerResponse = try await handlers.handleModels(ctx: ctx)
        default:
            return makeErrorResponse(404, "not found", cors: cors)
        }

        return formatResponse(handlerResponse, cors: cors)
    } catch {
        return makeErrorResponse(500, error.localizedDescription, cors: cors)
    }
}

/// Parse JSON body (empty data → empty dict).
public func parseJSONBody(_ data: Data) throws -> [String: Any] {
    guard !data.isEmpty else { return [:] }
    let obj = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = obj as? [String: Any] else {
        throw NSError(
            domain: "DVAIBridgeLlama",
            code: 400,
            userInfo: [NSLocalizedDescriptionKey: "Body must be a JSON object"]
        )
    }
    return dict
}

/// Convert a `HandlerResponse` into a framework-neutral `DVAIResponse`.
/// SSE responses become `.streaming` so the transport flushes chunks
/// to the consumer as they arrive (Hummingbird's `ResponseBody` writer
/// pattern); JSON / error responses become `.buffered`.
public func formatResponse(_ response: HandlerResponse, cors: [String: String]) -> DVAIResponse {
    switch response {
    case .json(let status, let body):
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
        var headers = cors
        headers["Content-Type"] = "application/json"
        return .buffered(status: status, headers: headers, body: data)

    case .sse(let stream):
        var headers = cors
        headers["Content-Type"] = "text/event-stream"
        headers["Cache-Control"] = "no-cache"
        headers["Connection"] = "keep-alive"
        // Tell intermediate proxies + browsers not to buffer.
        headers["X-Accel-Buffering"] = "no"
        return .streaming(status: 200, headers: headers, stream: stream)

    case .error(let status, let message):
        return makeErrorResponse(status, message, cors: cors)
    }
}

/// Build a JSON `{"error": "..."}` response with the given status.
public func makeErrorResponse(_ status: Int, _ message: String, cors: [String: String]) -> DVAIResponse {
    let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
    var headers = cors
    headers["Content-Type"] = "application/json"
    return .buffered(status: status, headers: headers, body: body)
}
