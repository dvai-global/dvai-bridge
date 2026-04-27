// Internal/FoundationHttpServer.swift
import Foundation
import Telegraph

/// Wraps Telegraph's `Server` with port-fallback bind logic.
///
/// Telegraph 0.40 exposes a synchronous, throwing `start(port:interface:)`
/// and a synchronous `stop(immediately:)`. We wrap those in an `actor` so
/// concurrent callers see consistent state.
actor FoundationHttpServer {
    private var server: Server?
    private(set) var boundPort: Int?

    init() {}

    /// Try to bind to `basePort`, falling back to `basePort+1`, ..., up to
    /// `maxAttempts` ports. Returns the port that bound successfully.
    /// Throws if all ports in the range are unavailable.
    func tryBind(basePort: Int, maxAttempts: Int, host: String) async throws -> Int {
        let lastPort = basePort + maxAttempts - 1

        for i in 0..<maxAttempts {
            let port = basePort + i
            let s = Server()
            do {
                try s.start(port: port, interface: host)
                self.server = s
                self.boundPort = port
                return port
            } catch {
                // Most likely "address in use"; ensure partial state is cleaned
                // up and try the next port.
                s.stop(immediately: true)
                continue
            }
        }

        let msg = "[DVAI] Could not bind HTTP transport to any port in range " +
                  "\(basePort)..\(lastPort) (all in use). " +
                  "Another local AI server may already be running."
        throw NSError(
            domain: "DVAIBridgeLlama",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
    }

    /// Stops the server. Idempotent — safe to call multiple times,
    /// including before any successful bind.
    func stop() {
        if let s = server {
            s.stop(immediately: true)
            server = nil
            boundPort = nil
        }
    }

    /// Install the standard 4-route OpenAI-compatible API + OPTIONS + 404 fallback.
    /// Each route delegates to `dispatchRoute` (HandlerDispatch.swift).
    ///
    /// Telegraph's route handlers are sync, but `dispatchRoute` is async
    /// (the protocol is async). We bridge sync→async via a semaphore.
    /// Acceptable for Phase 1; real-time streaming will need a different
    /// pattern.
    func installRoutes(handlers: DVAIHandlers, ctx: HandlerContext, corsConfig: CORSConfig) {
        guard let s = server else { return }

        let dispatchClosure: HTTPRequest.Handler = { request in
            let semaphore = DispatchSemaphore(value: 0)
            // Box the result so the @Sendable closure inside Task can mutate it
            // without violating Swift's exclusivity rules.
            let resultBox = ResultBox()
            Task {
                let resp = await dispatchRoute(
                    request: request,
                    handlers: handlers,
                    ctx: ctx,
                    corsConfig: corsConfig
                )
                resultBox.set(resp)
                semaphore.signal()
            }
            semaphore.wait()
            return resultBox.get() ?? HTTPResponse(.internalServerError)
        }

        // Specific routes first — Telegraph matches in registration order.
        s.route(.POST, "/v1/chat/completions", dispatchClosure)
        s.route(.POST, "/v1/completions", dispatchClosure)
        s.route(.POST, "/v1/embeddings", dispatchClosure)
        s.route(.GET, "/v1/models", dispatchClosure)

        // OPTIONS catch-all (CORS preflight) — regex matches any path.
        s.route(.OPTIONS, regex: "^/.*$", dispatchClosure)

        // Catch-all for unmatched paths — dispatchRoute returns 404 with
        // CORS headers so browsers see the correct response shape.
        s.route(.GET, regex: "^/.*$", dispatchClosure)
        s.route(.POST, regex: "^/.*$", dispatchClosure)
    }
}

/// Reference-typed box used to capture the dispatch result out of the
/// detached `Task` inside `installRoutes`. NSLock guards the single setter
/// against the (theoretical) case of waiter timeout vs. setter racing.
private final class ResultBox: @unchecked Sendable {
    private var value: HTTPResponse?
    private let lock = NSLock()
    func set(_ v: HTTPResponse) {
        lock.lock(); defer { lock.unlock() }
        value = v
    }
    func get() -> HTTPResponse? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
