// Internal/HttpServer.swift
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import NIOPosix
import ServiceLifecycle

/// Wraps a Hummingbird `Application` with port-fallback bind logic.
///
/// We migrated off Telegraph in v3.2.0 — Telegraph 0.40 buffers SSE
/// response bodies server-side, and its private `HTTPParserC` clang
/// module collides with `swift-nio`'s `CNIOLLHTTP` whenever a downstream
/// target imports both. Hummingbird (built on swift-nio) gives us
/// proper streaming SSE plus a single, consistent C-module footprint
/// across DVAISharedCore and DVAIBridge.
///
/// Public lifecycle (unchanged from the Telegraph era so existing
/// PluginState call sites compile without edits):
///
/// ```swift
/// let server = HttpServer()
/// await server.installRoutes(handlers: ..., ctx: ..., corsConfig: ...)
/// let port = try await server.tryBind(basePort: 38883, maxAttempts: 16, host: "127.0.0.1")
/// // …
/// await server.stop()
/// ```
///
/// Hummingbird requires the router at `Application` construction time,
/// so `installRoutes` captures the handlers/ctx/cors triple and defers
/// the actual `Application` build to `tryBind`.
public actor HttpServer {

    /// Captured handler triple — populated by `installRoutes`,
    /// consumed by `tryBind`.
    private struct PendingRoutes {
        let handlers: DVAIHandlers
        let ctx: HandlerContext
        let corsConfig: CORSConfig
    }

    /// Live application + service-group handle. `nil` before the
    /// first successful `tryBind` and after `stop()`.
    private struct Live {
        let port: Int
        let serviceGroup: ServiceGroup
        let runTask: Task<Void, Error>
    }

    private var pending: PendingRoutes?
    private var live: Live?

    /// Most recently bound port. `nil` before bind / after stop.
    public var boundPort: Int? { live?.port }

    public init() {}

    /// Capture the handler / context / CORS triple. Must be called
    /// before `tryBind`. Idempotent — the most recent call wins.
    public func installRoutes(
        handlers: DVAIHandlers,
        ctx: HandlerContext,
        corsConfig: CORSConfig
    ) {
        self.pending = PendingRoutes(handlers: handlers, ctx: ctx, corsConfig: corsConfig)
    }

    /// Try to bind to `basePort`, falling back to `basePort+1`, ..., up
    /// to `maxAttempts` ports. Returns the port that bound successfully.
    /// Throws if all ports in the range are unavailable, or if
    /// `installRoutes` was never called.
    public func tryBind(basePort: Int, maxAttempts: Int, host: String) async throws -> Int {
        guard let pending = self.pending else {
            throw NSError(
                domain: "DVAIBridge.HttpServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "tryBind() called before installRoutes()."]
            )
        }

        let lastPort = basePort + maxAttempts - 1

        for i in 0..<maxAttempts {
            let port = basePort + i
            do {
                let live = try await startApplication(
                    port: port,
                    host: host,
                    pending: pending
                )
                self.live = live
                return port
            } catch {
                // Most likely "address in use"; try the next port.
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

    /// Stops the server. Idempotent — safe to call multiple times.
    public func stop() async {
        guard let live else { return }
        await live.serviceGroup.triggerGracefulShutdown()
        // Wait for the run task to wind down. Errors during shutdown
        // (cancellation etc.) are expected and ignored.
        _ = try? await live.runTask.value
        self.live = nil
    }

    // MARK: - Private

    private func startApplication(
        port: Int,
        host: String,
        pending: PendingRoutes
    ) async throws -> Live {
        // Fast-fail port-availability probe. We try to bind a transient
        // BSD socket to the same host:port; if `bind(2)` fails the port
        // is in use and we can move on without ever standing up
        // Hummingbird (which would otherwise take seconds to error out).
        // There's a tiny TOCTOU race between this probe close and
        // Hummingbird's bind; that's the same window Telegraph + Ktor +
        // Kestrel have, and is acceptable for our use case.
        guard Self.portAvailable(host: host, port: port) else {
            throw NSError(
                domain: "DVAIBridge.HttpServer",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "port \(port) in use"]
            )
        }

        let handlers = pending.handlers
        let ctx = pending.ctx
        let corsConfig = pending.corsConfig

        let router = Router()

        // OpenAI-compatible API surface — every route delegates to
        // dispatchRoute, which produces a framework-neutral DVAIResponse.
        // We wire all four POST + GET endpoints AND a catch-all so
        // unmatched paths get the same CORS-aware 404 the Telegraph
        // version emitted.
        router.post("/v1/chat/completions") { req, _ in
            try await Self.handle(req, handlers: handlers, ctx: ctx, corsConfig: corsConfig)
        }
        router.post("/v1/completions") { req, _ in
            try await Self.handle(req, handlers: handlers, ctx: ctx, corsConfig: corsConfig)
        }
        router.post("/v1/embeddings") { req, _ in
            try await Self.handle(req, handlers: handlers, ctx: ctx, corsConfig: corsConfig)
        }
        router.get("/v1/models") { req, _ in
            try await Self.handle(req, handlers: handlers, ctx: ctx, corsConfig: corsConfig)
        }
        // OPTIONS catch-all (CORS preflight) for any path.
        router.on("/**", method: .options) { req, _ in
            try await Self.handle(req, handlers: handlers, ctx: ctx, corsConfig: corsConfig)
        }
        // GET / POST catch-all so unmatched paths get a CORS-aware 404
        // body shape (rather than Hummingbird's default 404).
        router.on("/**", method: .get) { req, _ in
            try await Self.handle(req, handlers: handlers, ctx: ctx, corsConfig: corsConfig)
        }
        router.on("/**", method: .post) { req, _ in
            try await Self.handle(req, handlers: handlers, ctx: ctx, corsConfig: corsConfig)
        }

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port),
                serverName: "DVAIBridge"
            ),
            logger: .init(label: "DVAIBridge.HttpServer")
        )

        // ServiceGroup gives us a clean graceful-shutdown handle.
        // We disable the default signal handlers so embedding apps
        // keep ownership of SIGINT / SIGTERM.
        let group = ServiceGroup(
            services: [app],
            gracefulShutdownSignals: [],
            cancellationSignals: [],
            logger: .init(label: "DVAIBridge.ServiceGroup")
        )

        // Spin the application on a detached task; probe TCP to detect
        // bind success (Hummingbird 2.x has no public did-bind hook).
        let runTask = Task<Void, Error> {
            try await group.run()
        }

        let probeStart = Date()
        while Date().timeIntervalSince(probeStart) < 5.0 {
            if runTask.isCancelled {
                break
            }
            if await Self.tcpProbe(host: host, port: port) {
                return Live(port: port, serviceGroup: group, runTask: runTask)
            }
            try await Task.sleep(nanoseconds: 25_000_000) // 25ms
        }

        // Probe timed out — assume bind failed. Trigger shutdown so the
        // run task winds down before we return the error to the caller.
        await group.triggerGracefulShutdown()
        _ = try? await runTask.value
        throw NSError(
            domain: "DVAIBridge.HttpServer",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Hummingbird app failed to bind \(host):\(port)"]
        )
    }

    /// Lightweight TCP probe used to detect "bind succeeded" since
    /// Hummingbird 2.x doesn't expose a did-bind hook. Returns true
    /// if the connection establishes; false on any error.
    private static func tcpProbe(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else { cont.resume(returning: false); return }
                defer { close(fd) }

                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port).bigEndian
                inet_pton(AF_INET, host == "0.0.0.0" ? "127.0.0.1" : host, &addr.sin_addr)

                let res = withUnsafePointer(to: &addr) { ptr -> Int32 in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                cont.resume(returning: res == 0)
            }
        }
    }

    /// Synchronous port-availability check via BSD `bind(2)`. We open
    /// a transient TCP socket, set SO_REUSEADDR off (the default), and
    /// attempt to bind. Success means the port is free; we close the
    /// socket and let the caller proceed. Failure means the port is
    /// occupied (EADDRINUSE etc.) and the caller should try the next.
    private static func portAvailable(host: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        let hostStr = (host == "0.0.0.0") ? "0.0.0.0" : host
        inet_pton(AF_INET, hostStr, &addr.sin_addr)

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }

    /// Translate a Hummingbird `Request` into a `DVAIRequest`, dispatch,
    /// then translate the `DVAIResponse` back into a Hummingbird
    /// `Response`. Buffered → in-memory body; streaming → ResponseBody
    /// closure that flushes each `String` chunk as a `ByteBuffer`.
    private static func handle(
        _ req: Request,
        handlers: DVAIHandlers,
        ctx: HandlerContext,
        corsConfig: CORSConfig
    ) async throws -> Response {
        // Materialise the body up to a generous cap (chat messages can
        // include base64 images). 16 MiB matches the Telegraph default.
        let bodyBuffer = try await req.body.collect(upTo: 16 * 1024 * 1024)
        let bodyData = Data(buffer: bodyBuffer)

        // Translate headers into a Swift dictionary. HTTPFields preserves
        // first-occurrence order; if a header repeats, comma-join the
        // values (RFC 7230 §3.2.2).
        var headers: [String: String] = [:]
        for field in req.headers {
            let name = field.name.canonicalName
            if let existing = headers[name] {
                headers[name] = existing + ", " + field.value
            } else {
                headers[name] = field.value
            }
        }

        let dvaiRequest = DVAIRequest(
            method: DVAIHttpMethod.from(req.method.rawValue),
            path: req.uri.path,
            headers: headers,
            body: bodyData
        )

        let dvaiResponse = await dispatchRoute(
            request: dvaiRequest,
            handlers: handlers,
            ctx: ctx,
            corsConfig: corsConfig
        )

        return Self.toHummingbirdResponse(dvaiResponse)
    }

    /// Convert a `DVAIResponse` into a Hummingbird `Response`. Shared
    /// helper so the streaming + buffered paths stay symmetric.
    private static func toHummingbirdResponse(_ resp: DVAIResponse) -> Response {
        switch resp {
        case .buffered(let status, let headers, let body):
            var fields = HTTPFields()
            for (k, v) in headers {
                if let name = HTTPField.Name(k) {
                    fields.append(HTTPField(name: name, value: v))
                }
            }
            return Response(
                status: .init(code: status),
                headers: fields,
                body: ResponseBody(byteBuffer: ByteBuffer(data: body))
            )

        case .streaming(let status, let headers, let stream):
            var fields = HTTPFields()
            for (k, v) in headers {
                if let name = HTTPField.Name(k) {
                    fields.append(HTTPField(name: name, value: v))
                }
            }
            return Response(
                status: .init(code: status),
                headers: fields,
                body: ResponseBody { writer in
                    for await chunk in stream {
                        if let bytes = chunk.data(using: .utf8), !bytes.isEmpty {
                            try await writer.write(ByteBuffer(data: bytes))
                        }
                    }
                    try await writer.finish(nil)
                }
            )
        }
    }
}
