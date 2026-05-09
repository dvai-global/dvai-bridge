import Foundation
import Network

/// LAN peer discovery via Apple's Network framework. Uses `NWBrowser`
/// with the Bonjour service-type `_dvai-bridge._tcp` and parses TXT
/// records into `MDNSPeer` values.
///
/// Mirrors the contract of `IDiscovery` in
/// `packages/dvai-bridge-core/src/discovery/types.ts`.
@available(iOS 14.0, macOS 11.0, *)
public actor NWBrowserDiscovery {
    public enum Event: Sendable {
        case peerUp(MDNSPeer)
        case peerDown(deviceId: String)
        case error(String)
    }

    private let browser: NWBrowser
    /// Map: endpointDescription → resolved peer. NWBrowser uses
    /// `NWBrowser.Result` whose endpoint is the stable identity for
    /// add/remove tracking.
    private var resultsByEndpoint: [String: MDNSPeer] = [:]
    private let continuation: AsyncStream<Event>.Continuation
    public nonisolated let events: AsyncStream<Event>
    private var started = false

    public init() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: DVAIBridgeMDNS.serviceType,
            domain: nil
        )
        self.browser = NWBrowser(for: descriptor, using: NWParameters())
        var savedContinuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream<Event> { c in
            savedContinuation = c
        }
        self.continuation = savedContinuation
    }

    /// Start browsing. Idempotent.
    public func start() {
        guard !started else { return }
        started = true

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            Task { await self.handleChanges(results: results, changes: changes) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleState(state) }
        }
        browser.start(queue: .global(qos: .utility))
    }

    /// Stop browsing. Idempotent.
    public func stop() {
        guard started else { return }
        started = false
        browser.cancel()
        continuation.finish()
    }

    /// Snapshot of currently-known peers.
    public func peers() -> [MDNSPeer] {
        Array(resultsByEndpoint.values)
    }

    private func handleState(_ state: NWBrowser.State) {
        switch state {
        case .failed(let err):
            continuation.yield(.error("NWBrowser failed: \(err)"))
        case .cancelled:
            continuation.yield(.error("NWBrowser cancelled"))
        default:
            break
        }
    }

    private func handleChanges(
        results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>
    ) {
        for change in changes {
            switch change {
            case .added(let result):
                if let peer = parsePeer(from: result) {
                    let key = endpointKey(result.endpoint)
                    resultsByEndpoint[key] = peer
                    continuation.yield(.peerUp(peer))
                }
            case .removed(let result):
                let key = endpointKey(result.endpoint)
                if let peer = resultsByEndpoint.removeValue(forKey: key) {
                    continuation.yield(.peerDown(deviceId: peer.deviceId))
                }
            case .changed(let old, let new, _):
                let oldKey = endpointKey(old.endpoint)
                let newKey = endpointKey(new.endpoint)
                if let peer = parsePeer(from: new) {
                    if oldKey != newKey {
                        resultsByEndpoint.removeValue(forKey: oldKey)
                    }
                    resultsByEndpoint[newKey] = peer
                    continuation.yield(.peerUp(peer))
                }
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    private func endpointKey(_ endpoint: NWEndpoint) -> String {
        return "\(endpoint)"
    }

    /// Parse an `NWBrowser.Result` (which carries the TXT metadata)
    /// into an `MDNSPeer`. Returns nil if the TXT record doesn't
    /// carry the minimum-required fields.
    private func parsePeer(from result: NWBrowser.Result) -> MDNSPeer? {
        guard case .bonjour(let txt) = result.metadata else { return nil }
        let dict = txt.dictionary
        guard let deviceId = dict["deviceId"], !deviceId.isEmpty else { return nil }
        let deviceName = dict["deviceName"] ?? "Unknown"
        let dvaiVersion = dict["dvaiVersion"] ?? "0.0.0"
        let portStr = dict["port"] ?? "38883"
        let port = Int(portStr) ?? 38883
        let secure = (dict["secure"] ?? "0") == "1"

        // Try to extract a host from the endpoint. NWBrowser endpoints
        // are typically `.service(name, type, domain, _)` form; the
        // resolved hostname:port comes through after a connection
        // resolves. For the offload module the baseUrl is the canonical
        // `http://{host}:{port}/v1` once we resolve, but at browse-time
        // we synthesize a placeholder using the bonjour service name.
        let host = bonjourServiceName(from: result.endpoint) ?? "unknown.local"
        let scheme = secure ? "https" : "http"
        let baseUrl = "\(scheme)://\(host):\(port)/v1"

        let loadedModels = (dict["models"] ?? "").split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
        let capability = parseCapability(dict["capability"]) ?? [:]

        return MDNSPeer(
            deviceId: deviceId,
            deviceName: deviceName,
            dvaiVersion: dvaiVersion,
            baseUrl: baseUrl,
            loadedModels: loadedModels,
            capability: capability,
            via: .mdns,
            secure: secure,
            lastSeenAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    private func bonjourServiceName(from endpoint: NWEndpoint) -> String? {
        if case .service(let name, _, _, _) = endpoint {
            // Bonjour service-instance names sometimes already carry a
            // `.local` suffix when the advertiser uses the device's
            // mDNS hostname (e.g. iPhone advertising as
            // `Deeps-iPhone.local`). Appending another `.local`
            // unconditionally produced URLs like
            // `http://deeps-iphone.local.local:38883` which fail to
            // resolve. Strip a trailing `.local` (and stray trailing
            // dot) BEFORE re-appending so the result is always
            // `<host>.local`.
            var trimmed = name
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
            if trimmed.hasSuffix(".local") {
                trimmed = String(trimmed.dropLast(".local".count))
            }
            return "\(trimmed).local"
        }
        return nil
    }

    private func parseCapability(_ raw: String?) -> [String: Double]? {
        guard let raw = raw, let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode([String: Double].self, from: data))
    }
}
