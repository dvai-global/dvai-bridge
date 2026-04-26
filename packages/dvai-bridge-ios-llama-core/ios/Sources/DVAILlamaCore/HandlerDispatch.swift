// Internal/HandlerDispatch.swift
import Foundation
import Telegraph

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

/// Builds the standard CORS + Private Network Access header set for a response.
///
/// Telegraph's `HTTPHeaders` is `[HTTPHeaderName: String]`, but its
/// `HTTPHeaderName` initializer is internal — we use the `String` subscript
/// extension defined on `HTTPHeaders` to set/read header values by raw name.
func corsHeaders(reqOrigin: String?, config: CORSConfig) -> [String: String] {
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

/// Apply a `[String: String]` header set onto a Telegraph response.
private func applyHeaders(_ headers: [String: String], to response: HTTPResponse) {
    for (k, v) in headers {
        response.headers[k] = v
    }
}

/// Dispatches a Telegraph HTTPRequest to the appropriate `DVAIHandlers` method.
///
/// - Catches handler errors and converts them to 500 responses.
/// - Handles `OPTIONS` preflight (204) and unknown routes (404).
/// - Adds CORS + PNA headers to every response.
func dispatchRoute(
    request: HTTPRequest,
    handlers: DVAIHandlers,
    ctx: HandlerContext,
    corsConfig: CORSConfig
) async -> HTTPResponse {
    let reqOrigin = request.headers["Origin"]
    let cors = corsHeaders(reqOrigin: reqOrigin, config: corsConfig)

    // OPTIONS preflight — respond 204 with CORS headers, no body.
    if request.method == .OPTIONS {
        let resp = HTTPResponse(.noContent)
        applyHeaders(cors, to: resp)
        return resp
    }

    let path = request.uri.path
    let method = request.method

    do {
        let handlerResponse: HandlerResponse
        switch (method, path) {
        case (.POST, "/v1/chat/completions"):
            let body = try parseJSONBody(request.body)
            handlerResponse = try await handlers.handleChatCompletion(body: body, ctx: ctx)
        case (.POST, "/v1/completions"):
            let body = try parseJSONBody(request.body)
            handlerResponse = try await handlers.handleCompletion(body: body, ctx: ctx)
        case (.POST, "/v1/embeddings"):
            let body = try parseJSONBody(request.body)
            handlerResponse = try await handlers.handleEmbeddings(body: body, ctx: ctx)
        case (.GET, "/v1/models"):
            handlerResponse = try await handlers.handleModels(ctx: ctx)
        default:
            return makeErrorResponse(404, "not found", cors: cors)
        }

        return try await formatResponse(handlerResponse, cors: cors)
    } catch {
        return makeErrorResponse(500, error.localizedDescription, cors: cors)
    }
}

/// Parse JSON body (empty data → empty dict).
func parseJSONBody(_ data: Data) throws -> [String: Any] {
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

/// Convert a `HandlerResponse` into a Telegraph `HTTPResponse` with CORS headers attached.
func formatResponse(_ response: HandlerResponse, cors: [String: String]) async throws -> HTTPResponse {
    switch response {
    case .json(let status, let body):
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        let resp = HTTPResponse(
            HTTPStatus(code: status, phrase: phraseFor(status)),
            body: data
        )
        resp.headers["Content-Type"] = "application/json"
        applyHeaders(cors, to: resp)
        return resp

    case .sse(let stream):
        // Collect all SSE chunks into a single body. Telegraph 0.40 doesn't
        // support true chunked-streaming responses on the server side
        // without lower-level surgery; for Phase 1, the SSE payload is
        // assembled and returned as one body. Real-time token streaming
        // can be added later if Telegraph's API supports it cleanly.
        var buf = Data()
        for await chunk in stream {
            if let bytes = chunk.data(using: .utf8) { buf.append(bytes) }
        }
        let resp = HTTPResponse(.ok, body: buf)
        resp.headers["Content-Type"] = "text/event-stream"
        resp.headers["Cache-Control"] = "no-cache"
        resp.headers["Connection"] = "keep-alive"
        applyHeaders(cors, to: resp)
        return resp

    case .error(let status, let message):
        return makeErrorResponse(status, message, cors: cors)
    }
}

/// Build a JSON `{"error": "..."}` response with the given status.
func makeErrorResponse(_ status: Int, _ message: String, cors: [String: String]) -> HTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
    let resp = HTTPResponse(
        HTTPStatus(code: status, phrase: phraseFor(status)),
        body: body
    )
    resp.headers["Content-Type"] = "application/json"
    applyHeaders(cors, to: resp)
    return resp
}

private func phraseFor(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    case 502: return "Bad Gateway"
    default: return "Status \(status)"
    }
}
