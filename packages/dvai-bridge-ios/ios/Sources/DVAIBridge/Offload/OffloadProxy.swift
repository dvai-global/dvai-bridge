import Foundation
import CryptoKit
#if !COCOAPODS
import Hummingbird
import HummingbirdCore
import NIOCore
import NIOHTTPTypes
import HTTPTypes

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
/// Lifecycle is owned by `DVAIBridge.shared.start(_:)`. Don't construct
/// from consumer code.
///
/// Streaming: built on Hummingbird (swift-nio) so SSE responses pipe
/// through cleanly — when the upstream peer / backend emits chunks,
/// the consumer sees them incrementally. The earlier Telegraph-based
/// implementation (v3.2.0-rc) buffered the whole body server-side,
/// breaking incremental token streaming through the proxy.
@available(iOS 14.0, macOS 14.0, *)
public actor OffloadProxy {

    /// Backend's internal loopback URL (e.g. `http://127.0.0.1:38983`).
    /// `nil` when the SDK is in offload-only mode (no backend).
    public let backendBaseUrl: String?
    public let offloadConfig: OffloadConfig
    public let pairingPolicy: PairingPolicy?
    /// Live snapshot of paired peers — re-read on each request so
    /// runtime additions are honored without restarting the proxy.
    public let peerProvider: @Sendable () async -> [MDNSPeer]
    public let appId: String
    public let selfDeviceId: String

    private var application: (any ApplicationProtocol)?
    private var serverTask: Task<Void, Error>?
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
        self.session = URLSession(configuration: cfg)
    }

    /// Bind the proxy. Tries `basePort..basePort+maxAttempts-1`.
    /// Returns the bound port.
    public func start(basePort: Int, maxAttempts: Int = 16, host: String = "127.0.0.1") async throws -> Int {
        precondition(application == nil, "OffloadProxy already started")

        var lastError: Error?
        for i in 0..<maxAttempts {
            let port = basePort + i
            do {
                let router = buildRouter()
                let app = Application(
                    router: router,
                    configuration: .init(
                        address: .hostname(host, port: port),
                        serverName: "dvai-offload-proxy"
                    )
                )
                // Start the server. Application.runService() blocks; we
                // run it in a Task and rely on the bound port being
                // exposed before the first request lands.
                let task = Task<Void, Error> {
                    try await app.runService()
                }
                self.application = app
                self.serverTask = task
                self.boundPort = port
                return port
            } catch {
                lastError = error
                continue
            }
        }
        throw NSError(
            domain: "OffloadProxy",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "OffloadProxy: failed to bind any port in \(basePort)..\(basePort + maxAttempts - 1) (\(lastError?.localizedDescription ?? "no detail"))"]
        )
    }

    /// Stop the proxy. Idempotent.
    public func stop() async {
        serverTask?.cancel()
        _ = try? await serverTask?.value
        serverTask = nil
        application = nil
        boundPort = -1
    }

    /// Public bind URL once started; nil before start().
    public func baseUrl() -> String? {
        return boundPort > 0 ? "http://127.0.0.1:\(boundPort)" : nil
    }

    public func currentPort() -> Int { boundPort }

    /* ================================================================== *
     * Hummingbird router                                                 *
     * ================================================================== */

    private nonisolated func buildRouter() -> Router<BasicRequestContext> {
        let router = Router(context: BasicRequestContext.self)
        // Catch-all on every method + path — the proxy decides per-request.
        router.on("/**", method: .get, use: { req, ctx in await self.handle(req: req, ctx: ctx) })
        router.on("/**", method: .post, use: { req, ctx in await self.handle(req: req, ctx: ctx) })
        router.on("/**", method: .options, use: { req, ctx in await self.handle(req: req, ctx: ctx) })
        return router
    }

    private func handle(req: Request, ctx: BasicRequestContext) async -> Response {
        let path = req.uri.path
        let bodyData: Data
        do {
            bodyData = try await collectBody(req.body)
        } catch {
            return jsonResponse(status: .badGateway,
                body: #"{"error":{"type":"proxy_error","code":502,"message":"\#(escapeJson(error.localizedDescription))"}}"#)
        }

        // v3.2.1 — incoming pairing handshake. The TS-side handler
        // (packages/dvai-bridge-core/src/handlers/dvai/index.ts:110)
        // is wire-compatible with this one: same body shape, same
        // response keys. We special-case the path BEFORE
        // `decideRoute` so the request never tries to forward to a
        // peer or the (nil-in-offload-only) local backend — both
        // would 404/502.
        if path == "/v1/dvai/handshake" {
            return await handleHandshakeRequest(method: req.method, body: bodyData)
        }

        // Build a lower-cased header map for decision + forwarding.
        var headerMap: [String: String] = [:]
        for f in req.headers {
            headerMap[f.name.canonicalName.lowercased()] = f.value
        }

        let decision = await decideRoute(path: path, body: bodyData, headers: headerMap)
        switch decision {
        case .local:
            return await forwardToLocal(method: req.method, path: path, body: bodyData, headers: req.headers)
        case .offload(let baseUrl, let peerDeviceId):
            return await forwardToPeer(
                baseUrl: baseUrl,
                peerDeviceId: peerDeviceId,
                method: req.method,
                path: path,
                body: bodyData,
                headers: req.headers
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

        // v3.2.1 — paired-peer fallback. `pickBestPeer` filters by
        // `capability[modelId] > 0`, but a freshly-discovered Hub
        // (mDNS-only, no benchmark run yet) advertises an empty
        // capability map → every peer scores 0 → `best == nil` even
        // though the peer is reachable AND we have a valid pairing.
        //
        // Two-stage fallback:
        //   (a) prefer a discovered peer that we have an active
        //       pairing for (lets us pick up TXT-record updates etc.);
        //   (b) if discovery is dark for the paired peer (the macOS
        //       Hub case — Node's `multicast-dns` lib can't advertise
        //       through mDNSResponder), fall back to the pairing's
        //       persisted baseUrl. The pairing is what proves
        //       authorisation; the baseUrl is just routing info.
        let pairedFallback: (baseUrl: String, peerDeviceId: String)? = await {
            guard let policy = pairingPolicy else { return nil }
            // (a) pairing + discovered.
            for p in peers {
                if await policy.getActive(peerDeviceId: p.deviceId) != nil {
                    return (p.baseUrl, p.deviceId)
                }
            }
            // (b) pairing only — uses the baseUrl captured at
            // pairing time. `getActive` filters out expired records.
            for pairing in await policy.listPairings() {
                if let baseUrl = pairing.baseUrl,
                   await policy.getActive(peerDeviceId: pairing.peerDeviceId) != nil {
                    return (baseUrl, pairing.peerDeviceId)
                }
            }
            return nil
        }()

        if offloadHeader == "require" {
            if let best {
                return .offload(baseUrl: best.peer.baseUrl, peerDeviceId: best.peer.deviceId)
            }
            if let fallback = pairedFallback {
                return .offload(baseUrl: fallback.baseUrl, peerDeviceId: fallback.peerDeviceId)
            }
            return .noCapableDevice(
                json: noCapableDeviceError(localCapability: 0, required: threshold)
            )
        }

        // header == "prefer" (default)
        if let best, best.score >= threshold {
            return .offload(baseUrl: best.peer.baseUrl, peerDeviceId: best.peer.deviceId)
        }
        // No capability-match candidate. If we're offload-only AND
        // have a paired peer, route to it; the alternative is a 503
        // even though offload is fully wired.
        if backendBaseUrl == nil, let fallback = pairedFallback {
            return .offload(baseUrl: fallback.baseUrl, peerDeviceId: fallback.peerDeviceId)
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
     * Forwarding (URLSession streaming on the upstream leg, Hummingbird  *
     * AsyncStream on the response leg)                                   *
     * ================================================================== */

    private func forwardToLocal(
        method: HTTPRequest.Method,
        path: String,
        body: Data,
        headers: HTTPFields
    ) async -> Response {
        guard let backend = backendBaseUrl else {
            return jsonResponse(status: .serviceUnavailable, body: noLocalBackendError())
        }
        let target = "\(stripTrailing(backend, suffix: "/"))\(path)"
        return await forward(target: target, method: method, body: body, headers: headers,
                             signRequest: false, peerDeviceId: nil)
    }

    private func forwardToPeer(
        baseUrl: String,
        peerDeviceId: String,
        method: HTTPRequest.Method,
        path: String,
        body: Data,
        headers: HTTPFields
    ) async -> Response {
        // The incoming `path` always carries the `/v1/...` prefix the
        // OpenAI client supplied (e.g. `/v1/chat/completions`).
        // Discovered peer baseUrls also carry `/v1` (NWBrowserDiscovery
        // synthesises them as `<scheme>://<host>:<port>/v1`). Naive
        // concatenation produces `…/v1/v1/chat/completions`, which the
        // peer 404s. Strip a trailing `/v1` from the baseUrl before
        // appending the path so we always end up with a single `/v1`.
        var normalisedBase = stripTrailing(baseUrl, suffix: "/")
        if normalisedBase.hasSuffix("/v1") {
            normalisedBase = String(normalisedBase.dropLast("/v1".count))
        }
        let normalizedPath = path.hasPrefix("/v1")
            ? path
            : "/v1" + (path.hasPrefix("/") ? path : "/" + path)
        let target = "\(normalisedBase)\(normalizedPath)"
        return await forward(target: target, method: method, body: body, headers: headers,
                             signRequest: true, peerDeviceId: peerDeviceId)
    }

    private func forward(
        target: String,
        method: HTTPRequest.Method,
        body: Data,
        headers: HTTPFields,
        signRequest: Bool,
        peerDeviceId: String?
    ) async -> Response {
        guard let url = URL(string: target) else {
            return jsonResponse(status: .badGateway,
                body: #"{"error":{"type":"proxy_error","code":502,"message":"invalid forward target"}}"#)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.rawValue
        urlRequest.httpBody = body.isEmpty ? nil : body

        for f in headers {
            let nameStr = f.name.canonicalName
            let lk = nameStr.lowercased()
            if hopByHop.contains(lk) || lk == "host" || lk == "content-length" { continue }
            urlRequest.setValue(f.value, forHTTPHeaderField: nameStr)
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if signRequest, let peerDeviceId, let policy = pairingPolicy {
            if let pairing = await policy.getActive(peerDeviceId: peerDeviceId) {
                let nonce = PairingHandshake.generateNonce()
                // v3.2.1 — route through the canonical PairingHandshake
                // helpers instead of the local `signCanonical`. The
                // local one had THREE protocol bugs vs the TS Hub's
                // verifier (Hub returned 401 every time):
                //   - canonical msg order: TS uses
                //       `nonce\nMETHOD\npath\nsha256hex(body)`;
                //     local used `METHOD\npath\nnonce\nbody-bytes`.
                //   - pairingKey encoding: TS decodes base64-url;
                //     local used raw UTF-8 bytes.
                //   - signature encoding: TS produces base64-url;
                //     local emitted hex.
                // PairingHandshake.composeSignedMessage + signHmac
                // already match the TS reference byte-for-byte;
                // they were just unused by the proxy.
                let bodyString = body.isEmpty ? nil : String(data: body, encoding: .utf8) ?? ""
                let canonical = PairingHandshake.composeSignedMessage(
                    nonce: nonce,
                    method: method.rawValue,
                    path: url.path,
                    body: bodyString
                )
                if let signature = try? PairingHandshake.signHmac(
                    pairingKey: pairing.pairingKey,
                    message: canonical
                ) {
                    urlRequest.setValue(selfDeviceId, forHTTPHeaderField: "X-DVAI-Peer-Device-Id")
                    urlRequest.setValue(appId, forHTTPHeaderField: "X-DVAI-App-Id")
                    urlRequest.setValue(nonce, forHTTPHeaderField: "X-DVAI-Nonce")
                    urlRequest.setValue(signature, forHTTPHeaderField: "X-DVAI-Signature")
                    urlRequest.setValue("1", forHTTPHeaderField: "X-DVAI-Forwarded")
                }
            }
        }

        do {
            let (asyncBytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                return jsonResponse(status: .badGateway,
                    body: #"{"error":{"type":"peer_unreachable","code":502,"message":"non-HTTP response from upstream"}}"#)
            }

            // Build response headers, dropping hop-by-hop + Content-Length.
            var outHeaders = HTTPFields()
            for (key, value) in http.allHeaderFields {
                let k = "\(key)"
                let lk = k.lowercased()
                if hopByHop.contains(lk) || lk == "content-length" { continue }
                if let nameKey = HTTPField.Name(k) {
                    outHeaders.append(HTTPField(name: nameKey, value: "\(value)"))
                }
            }
            // Default content-type to JSON if upstream omitted.
            if outHeaders[.contentType] == nil {
                outHeaders.append(HTTPField(name: .contentType, value: "application/json"))
            }

            // Stream the upstream body back via ResponseBody.withTrailingHeaders
            // closure. asyncBytes yields UInt8 chunks; we buffer per-line and
            // emit ByteBuffers downstream so the consumer sees incremental
            // tokens for SSE.
            let status = HTTPResponse.Status(code: http.statusCode)
            return Response(
                status: status,
                headers: outHeaders,
                body: ResponseBody { writer in
                    var chunkBuf: [UInt8] = []
                    chunkBuf.reserveCapacity(8192)
                    for try await byte in asyncBytes {
                        chunkBuf.append(byte)
                        // Flush on newline or every 8 KB so SSE chunks land
                        // promptly without per-byte writes.
                        if byte == 0x0A || chunkBuf.count >= 8192 {
                            try await writer.write(ByteBuffer(bytes: chunkBuf))
                            chunkBuf.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunkBuf.isEmpty {
                        try await writer.write(ByteBuffer(bytes: chunkBuf))
                    }
                    try await writer.finish(nil)
                }
            )
        } catch {
            return jsonResponse(status: .badGateway,
                body: #"{"error":{"type":"peer_unreachable","code":502,"message":"\#(escapeJson(error.localizedDescription))"}}"#)
        }
    }

    private func collectBody(_ body: RequestBody) async throws -> Data {
        var out = Data()
        for try await buffer in body {
            out.append(contentsOf: buffer.readableBytesView)
            if out.count > MAX_REQUEST_BYTES {
                throw NSError(domain: "OffloadProxy", code: 413,
                    userInfo: [NSLocalizedDescriptionKey: "request body exceeds \(MAX_REQUEST_BYTES) bytes"])
            }
        }
        return out
    }

    private func readModelId(from body: Data) -> String? {
        guard !body.isEmpty,
              let any = try? JSONSerialization.jsonObject(with: body),
              let dict = any as? [String: Any] else {
            return nil
        }
        return dict["model"] as? String
    }

    private nonisolated func noLocalBackendError() -> String {
        #"{"error":{"type":"no_local_backend","code":503,"message":"DVAI is in offload-only mode and no peer is available."}}"#
    }

    private nonisolated func noCapableDeviceError(localCapability: Double, required: Double) -> String {
        #"{"error":{"type":"no_capable_device","code":503,"message":"No device with capability >= \#(required) tok/s available.","localCapability":\#(localCapability),"requiredAtLeast":\#(required)}}"#
    }

    private func handleHandshakeRequest(method: HTTPRequest.Method, body: Data) async -> Response {
        guard method == .post else {
            return jsonResponse(
                status: .methodNotAllowed,
                body: #"{"error":{"type":"method_not_allowed","message":"POST required"}}"#
            )
        }
        guard let policy = pairingPolicy else {
            return jsonResponse(
                status: .serviceUnavailable,
                body: #"{"error":{"type":"pairing_disabled","message":"pairing not configured"}}"#
            )
        }

        guard let json = (try? JSONSerialization.jsonObject(with: body, options: [])) as? [String: Any] else {
            return jsonResponse(
                status: .badRequest,
                body: #"{"error":{"type":"malformed_handshake","message":"body must be a JSON object"}}"#
            )
        }
        guard let peerDeviceId = json["peerDeviceId"] as? String, !peerDeviceId.isEmpty,
              let peerDeviceName = json["peerDeviceName"] as? String, !peerDeviceName.isEmpty else {
            return jsonResponse(
                status: .badRequest,
                body: #"{"error":{"type":"malformed_handshake","message":"missing peerDeviceId / peerDeviceName"}}"#
            )
        }
        let viaRaw = (json["via"] as? String) ?? "lan-handshake"
        let via = Pairing.Via(rawValue: viaRaw) ?? .lanHandshake

        do {
            let pairing = try await policy.approveOrFetch(
                peerDeviceId: peerDeviceId,
                peerDeviceName: peerDeviceName,
                via: via
            )
            let payload: [String: Any] = [
                "paired": true,
                "pairedAt": pairing.pairedAt,
                "via": pairing.via.rawValue,
                "pairingKey": pairing.pairingKey,
                "peerDeviceId": pairing.peerDeviceId,
            ]
            let bodyData = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
            return jsonResponse(
                status: .ok,
                body: String(data: bodyData, encoding: .utf8) ?? "{}"
            )
        } catch {
            return jsonResponse(
                status: .forbidden,
                body: #"{"error":{"type":"pairing_denied","message":"\#(escapeJson(error.localizedDescription))"}}"#
            )
        }
    }

    private nonisolated func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        var headers = HTTPFields()
        headers.append(HTTPField(name: .contentType, value: "application/json"))
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(string: body)))
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

private let MAX_REQUEST_BYTES = 32 * 1024 * 1024
#else
public actor OffloadProxy {
    public let backendBaseUrl: String?
    public let offloadConfig: OffloadConfig
    public let pairingPolicy: PairingPolicy?
    public let peerProvider: @Sendable () async -> [MDNSPeer]
    public let appId: String
    public let selfDeviceId: String

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
    }

    public func start(basePort: Int, maxAttempts: Int = 16, host: String = "127.0.0.1") async throws -> Int {
        throw NSError(domain: "OffloadProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "OffloadProxy is not supported in CocoaPods builds. Use SwiftPM for offloading support."])
    }

    public func stop() async {}
    public func baseUrl() -> String? { nil }
    public func currentPort() -> Int { -1 }
}
#endif
