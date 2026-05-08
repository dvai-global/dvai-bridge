import Foundation
import CryptoKit
import Telegraph

/// v3.2 — Pre-routing HTTP proxy for the iOS SDK.
///
/// Architecture mirrors the Android Ktor-based OffloadProxy 1:1:
///
///     consumer app -> http://127.0.0.1:proxyPort/v1/...
///                          |
///                          +-- if local-decision  -> http://127.0.0.1:backendPort/v1/...
///                          +-- if offload-decision -> peer baseUrl
///                                  (HMAC-SHA256: X-DVAI-Peer-Device-Id +
///                                                X-DVAI-App-Id +
///                                                X-DVAI-Nonce +
///                                                X-DVAI-Signature)
///
/// Lifecycle is owned by `DVAIBridge.shared.start()`. Don't construct
/// from consumer code.
///
/// Streaming caveat: Telegraph 0.40 buffers SSE bodies server-side
/// (the same limitation the existing iOS llama backend hits when
/// serving SSE responses). For v3.2.0 we accept this — chat completion
/// still works, the user just doesn't see incremental tokens until the
/// upstream finishes. v3.2.x can swap Telegraph for a streaming-capable
/// HTTP server (Hummingbird, swift-nio-http1) without changing the
/// public API.
@available(iOS 14.0, macOS 11.0, *)
public actor OffloadProxy {

    /// Backend's internal loopback URL (e.g. `http://127.0.0.1:38983`).
    /// `nil` when the SDK is in offload-only mode (no backend).
    public let backendBaseUrl: String?
    public let offloadConfig: OffloadConfig
    public let pairingPolicy: PairingPolicy?
    /// Live snapshot of paired peers — re-read on each request so
    /// runtime additions are honored without restarting the proxy.
    /// `async` because `NWBrowserDiscovery` is an actor.
    public let peerProvider: @Sendable () async -> [MDNSPeer]
    public let appId: String
    public let selfDeviceId: String

    private var server: Telegraph.Server?
    private var boundPort: Int = -1
    private let session: URLSession

    public init(
        backendBaseUrl: String?,
        offloadConfig: OffloadConfig,
        pairingPolicy: PairingPolicy?,
        peerProvider: @escaping @Sendable () async -> [MDNSPeer],
        appId: String,
        selfDeviceId: String
    ) {
        self.backendBaseUrl = backendBaseUrl
        self.offloadConfig = offloadConfig
        self.pairingPolicy = pairingPolicy
        self.peerProvider = peerProvider
        self.appId = appId
        self.selfDeviceId = selfDeviceId

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 600
        cfg.httpAdditionalHeaders = [:]
        self.session = URLSession(configuration: cfg)
    }

    /// Bind the proxy. Tries `basePort..basePort+maxAttempts-1`.
    /// Returns the bound port.
    public func start(basePort: Int, maxAttempts: Int = 16, host: String = "127.0.0.1") throws -> Int {
        precondition(server == nil, "OffloadProxy already started")
        var lastError: Error?
        for i in 0..<maxAttempts {
            let port = basePort + i
            let s = Telegraph.Server()
            installRoutes(on: s)
            do {
                try s.start(port: port, interface: host)
                self.server = s
                self.boundPort = port
                return port
            } catch {
                lastError = error
                s.stop(immediately: true)
                continue
            }
        }
        throw NSError(
            domain: "OffloadProxy",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "OffloadProxy: failed to bind any port in \(basePort)..\(basePort + maxAttempts - 1)"]
        )
    }

    /// Stop the proxy. Idempotent.
    public func stop() {
        server?.stop(immediately: true)
        server = nil
        boundPort = -1
    }

    /// Public bind URL once started; nil before start().
    public func baseUrl() -> String? {
        return boundPort > 0 ? "http://127.0.0.1:\(boundPort)" : nil
    }

    public func currentPort() -> Int { boundPort }

    /* ================================================================== *
     * Route registration                                                 *
     * ================================================================== */

    private nonisolated func installRoutes(on s: Telegraph.Server) {
        // Catch-all: every request goes through the proxy decision logic.
        let handler: HTTPRequest.Handler = { [weak self] request in
            guard let self else {
                return HTTPResponse(.serviceUnavailable, content: "proxy gone")
            }
            return self.handleSync(request: request)
        }
        // Specific routes first (Telegraph matches in registration order).
        s.route(.POST, "/v1/chat/completions", handler)
        s.route(.POST, "/v1/completions", handler)
        s.route(.POST, "/v1/embeddings", handler)
        s.route(.GET, "/v1/models", handler)
        s.route(.OPTIONS, regex: "^/.*$", handler)
        s.route(.GET, regex: "^/.*$", handler)
        s.route(.POST, regex: "^/.*$", handler)
    }

    /// Sync entry-point Telegraph calls; bridges to async via a
    /// semaphore. Same pattern as `HttpServer.installRoutes` in
    /// shared-core. Acceptable for v3.2.0 — Telegraph doesn't stream.
    private nonisolated func handleSync(request: HTTPRequest) -> HTTPResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task {
            let resp = await self.handle(request: request)
            box.set(resp)
            semaphore.signal()
        }
        semaphore.wait()
        return box.get() ?? HTTPResponse(.internalServerError)
    }

    private func handle(request: HTTPRequest) async -> HTTPResponse {
        let path = request.uri.path
        let body = request.body
        let headers = lowerCasedHeaders(request.headers)

        let decision = await decideRoute(path: path, body: body, headers: headers)
        switch decision {
        case .local:
            return await forwardToLocal(request: request)
        case .offload(let baseUrl, let peerDeviceId):
            return await forwardToPeer(
                baseUrl: baseUrl,
                peerDeviceId: peerDeviceId,
                request: request
            )
        case .noCapableDevice(let json):
            return jsonResponse(status: .serviceUnavailable, body: json)
        }
    }

    /* ================================================================== *
     * Decision                                                           *
     * ================================================================== */

    public enum RouteDecision: Sendable {
        case local
        case offload(baseUrl: String, peerDeviceId: String)
        case noCapableDevice(json: String)
    }

    public func decideRoute(
        path: String,
        body: Data,
        headers: [String: String]
    ) async -> RouteDecision {
        let isChatCompletion = path.hasSuffix("/chat/completions") ||
            path.hasSuffix("/v1/chat/completions")

        if !isChatCompletion {
            return backendBaseUrl != nil ? .local : .noCapableDevice(json: noLocalBackendError())
        }

        if !offloadConfig.enabled {
            return backendBaseUrl != nil ? .local : .noCapableDevice(json: noLocalBackendError())
        }

        let offloadHeader = (headers["x-dvai-offload"] ?? "prefer").lowercased()
        if offloadHeader == "never" {
            return backendBaseUrl != nil ? .local : .noCapableDevice(json: noLocalBackendError())
        }

        let modelId = readModelId(from: body) ?? ""
        let peers = await peerProvider()
        let best = pickBestPeer(peers: peers, modelId: modelId)
        let threshold = offloadConfig.minLocalCapability

        if offloadHeader == "require" {
            if let best {
                return .offload(baseUrl: best.peer.baseUrl, peerDeviceId: best.peer.deviceId)
            }
            return .noCapableDevice(
                json: noCapableDeviceError(localCapability: 0, required: threshold)
            )
        }

        // header == "prefer" (default)
        if let best, best.score >= threshold {
            return .offload(baseUrl: best.peer.baseUrl, peerDeviceId: best.peer.deviceId)
        }
        if backendBaseUrl != nil { return .local }
        return .noCapableDevice(
            json: noCapableDeviceError(localCapability: 0, required: threshold)
        )
    }

    public struct RankedPeer: Sendable, Equatable {
        public let peer: MDNSPeer
        public let score: Double
        public let hasModel: Bool
    }

    public func pickBestPeer(peers: [MDNSPeer], modelId: String) -> RankedPeer? {
        let ranked = peers.compactMap { p -> RankedPeer? in
            let score = p.capability[modelId] ?? 0
            if score <= 0 { return nil }
            return RankedPeer(peer: p, score: score, hasModel: p.loadedModels.contains(modelId))
        }
        .sorted { lhs, rhs in
            if lhs.hasModel != rhs.hasModel { return lhs.hasModel }
            return lhs.score > rhs.score
        }
        return ranked.first
    }

    /* ================================================================== *
     * Forwarding                                                         *
     * ================================================================== */

    private func forwardToLocal(request: HTTPRequest) async -> HTTPResponse {
        guard let backend = backendBaseUrl else {
            return jsonResponse(status: .serviceUnavailable, body: noLocalBackendError())
        }
        let target = "\(stripTrailing(backend, suffix: "/"))\(request.uri.path)"
        return await forward(
            target: target,
            request: request,
            signRequest: false,
            peerDeviceId: nil
        )
    }

    private func forwardToPeer(
        baseUrl: String,
        peerDeviceId: String,
        request: HTTPRequest
    ) async -> HTTPResponse {
        let normalizedPath = request.uri.path.hasPrefix("/v1")
            ? request.uri.path
            : "/v1" + (request.uri.path.hasPrefix("/") ? request.uri.path : "/" + request.uri.path)
        let target = "\(stripTrailing(baseUrl, suffix: "/"))\(normalizedPath)"
        return await forward(
            target: target,
            request: request,
            signRequest: true,
            peerDeviceId: peerDeviceId
        )
    }

    private func forward(
        target: String,
        request: HTTPRequest,
        signRequest: Bool,
        peerDeviceId: String?
    ) async -> HTTPResponse {
        guard let url = URL(string: target) else {
            return jsonResponse(
                status: .badGateway,
                body: #"{"error":{"type":"proxy_error","code":502,"message":"invalid forward target"}}"#
            )
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.name
        urlRequest.httpBody = request.body.isEmpty ? nil : request.body

        // Copy through headers, dropping hop-by-hop + content-length.
        // Telegraph's HTTPHeaders maps HTTPHeaderName → String;
        // HTTPHeaderName has a `name: String` property we use for the
        // URLRequest header field name and lowercased filtering.
        for (k, v) in request.headers {
            let nameStr = String(describing: k)
            let lk = nameStr.lowercased()
            if hopByHop.contains(lk) || lk == "host" || lk == "content-length" { continue }
            urlRequest.setValue(v, forHTTPHeaderField: nameStr)
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // HMAC-sign for peer forwards.
        if signRequest, let peerDeviceId, let policy = pairingPolicy {
            if let pairing = await policy.getActive(peerDeviceId: peerDeviceId) {
                let nonce = newNonce()
                let signature = signCanonical(
                    method: request.method.name,
                    path: url.path,
                    body: request.body,
                    nonce: nonce,
                    pairingKey: pairing.pairingKey
                )
                urlRequest.setValue(selfDeviceId, forHTTPHeaderField: "X-DVAI-Peer-Device-Id")
                urlRequest.setValue(appId, forHTTPHeaderField: "X-DVAI-App-Id")
                urlRequest.setValue(nonce, forHTTPHeaderField: "X-DVAI-Nonce")
                urlRequest.setValue(signature, forHTTPHeaderField: "X-DVAI-Signature")
                urlRequest.setValue("1", forHTTPHeaderField: "X-DVAI-Forwarded")
            }
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                return jsonResponse(
                    status: .badGateway,
                    body: #"{"error":{"type":"peer_unreachable","code":502,"message":"non-HTTP response from upstream"}}"#
                )
            }
            let resp = HTTPResponse(
                HTTPStatus(code: http.statusCode, phrase: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
            )
            resp.body = data
            for (key, value) in http.allHeaderFields {
                let k = "\(key)"
                let lk = k.lowercased()
                if hopByHop.contains(lk) || lk == "content-length" { continue }
                resp.headers[k] = "\(value)"
            }
            // If upstream didn't say Content-Type, default to JSON so
            // the consumer's OpenAI client doesn't choke.
            if resp.headers["Content-Type"] == nil {
                resp.headers["Content-Type"] = "application/json"
            }
            return resp
        } catch {
            return jsonResponse(
                status: .badGateway,
                body: #"{"error":{"type":"peer_unreachable","code":502,"message":"\#(escapeJson(error.localizedDescription))"}}"#
            )
        }
    }

    /* ================================================================== *
     * HMAC                                                               *
     * ================================================================== */

    private func signCanonical(
        method: String,
        path: String,
        body: Data,
        nonce: String,
        pairingKey: String
    ) -> String {
        var msg = Data()
        msg.append(method.uppercased().data(using: .utf8) ?? Data())
        msg.append(0x0A)
        msg.append(path.data(using: .utf8) ?? Data())
        msg.append(0x0A)
        msg.append(nonce.data(using: .utf8) ?? Data())
        msg.append(0x0A)
        msg.append(body)
        let key = SymmetricKey(data: pairingKey.data(using: .utf8) ?? Data())
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func newNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /* ================================================================== *
     * Helpers                                                            *
     * ================================================================== */

    private func readModelId(from body: Data) -> String? {
        guard !body.isEmpty,
              let any = try? JSONSerialization.jsonObject(with: body),
              let dict = any as? [String: Any] else {
            return nil
        }
        return dict["model"] as? String
    }

    private nonisolated func lowerCasedHeaders(_ headers: HTTPHeaders) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in headers {
            out[String(describing: k).lowercased()] = v
        }
        return out
    }

    private nonisolated func noLocalBackendError() -> String {
        #"{"error":{"type":"no_local_backend","code":503,"message":"DVAI is in offload-only mode and no peer is available."}}"#
    }

    private nonisolated func noCapableDeviceError(localCapability: Double, required: Double) -> String {
        #"{"error":{"type":"no_capable_device","code":503,"message":"No device with capability >= \#(required) tok/s available.","localCapability":\#(localCapability),"requiredAtLeast":\#(required)}}"#
    }

    private nonisolated func jsonResponse(status: HTTPStatus, body: String) -> HTTPResponse {
        let resp = HTTPResponse(status, content: body)
        resp.headers["Content-Type"] = "application/json"
        return resp
    }

    private nonisolated func stripTrailing(_ s: String, suffix: String) -> String {
        s.hasSuffix(suffix) ? String(s.dropLast(suffix.count)) : s
    }

    private nonisolated func escapeJson(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private let hopByHop: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailers", "transfer-encoding", "upgrade", "host",
    ]
}

/// Reference-typed box used to capture the dispatch result from the
/// detached `Task` inside `handleSync`. Same pattern as `ResultBox`
/// in shared-core's `HttpServer`.
private final class ResponseBox: @unchecked Sendable {
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
