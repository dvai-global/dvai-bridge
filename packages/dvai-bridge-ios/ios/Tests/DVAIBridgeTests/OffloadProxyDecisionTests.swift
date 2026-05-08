import XCTest
@testable import DVAIBridge

/// v3.2 — pre-routing decision logic on iOS (Swift parallel to
/// Android's OffloadProxyDecisionTest.kt). Constructs an
/// OffloadProxy with a synthetic peerProvider closure and exercises
/// `decideRoute` and `pickBestPeer` directly — no Hummingbird server
/// is bound, no network I/O.
@available(iOS 14.0, macOS 14.0, *)
final class OffloadProxyDecisionTests: XCTestCase {

    private func makeProxy(
        backendBaseUrl: String? = "http://127.0.0.1:38983",
        offloadEnabled: Bool = true,
        minLocalCapability: Double = 10.0,
        peers: [MDNSPeer] = []
    ) -> OffloadProxy {
        let cfg = OffloadConfig(enabled: offloadEnabled, minLocalCapability: minLocalCapability)
        return OffloadProxy(
            backendBaseUrl: backendBaseUrl,
            offloadConfig: cfg,
            pairingPolicy: nil,
            peerProvider: { peers },
            appId: "test.app",
            selfDeviceId: "test-self-device"
        )
    }

    private func makePeer(
        deviceId: String,
        capability: [String: Double],
        loadedModels: [String] = []
    ) -> MDNSPeer {
        MDNSPeer(
            deviceId: deviceId,
            deviceName: "\(deviceId)-name",
            dvaiVersion: "3.2.0",
            baseUrl: "http://10.0.0.1:38883",
            loadedModels: loadedModels,
            capability: capability,
            via: .mdns
        )
    }

    /* ------------------------------------------------------------------ */
    /* pickBestPeer                                                       */
    /* ------------------------------------------------------------------ */

    func testPickBestPeerReturnsNilWhenNoPeers() async {
        let proxy = makeProxy()
        let best = await proxy.pickBestPeer(peers: [], modelId: "model-a")
        XCTAssertNil(best)
    }

    func testPickBestPeerPrefersHigherScore() async {
        let proxy = makeProxy()
        let a = makePeer(deviceId: "a", capability: ["model-a": 5.0])
        let b = makePeer(deviceId: "b", capability: ["model-a": 30.0])
        let c = makePeer(deviceId: "c", capability: ["model-a": 12.0])
        let best = await proxy.pickBestPeer(peers: [a, b, c], modelId: "model-a")
        XCTAssertEqual(best?.peer.deviceId, "b")
    }

    func testPickBestPeerPrefersLoadedModel() async {
        let proxy = makeProxy()
        let notLoaded = makePeer(deviceId: "a", capability: ["model-a": 30.0])
        let loaded = makePeer(deviceId: "b", capability: ["model-a": 20.0], loadedModels: ["model-a"])
        let best = await proxy.pickBestPeer(peers: [notLoaded, loaded], modelId: "model-a")
        XCTAssertEqual(best?.peer.deviceId, "b")
        XCTAssertTrue(best!.hasModel)
    }

    func testPickBestPeerSkipsZeroScore() async {
        let proxy = makeProxy()
        let none = makePeer(deviceId: "a", capability: ["other": 100.0])
        let zero = makePeer(deviceId: "b", capability: ["model-a": 0.0])
        let best = await proxy.pickBestPeer(peers: [none, zero], modelId: "model-a")
        XCTAssertNil(best)
    }

    /* ------------------------------------------------------------------ */
    /* decideRoute                                                        */
    /* ------------------------------------------------------------------ */

    func testDecideRouteNonChatPathIsLocal() async {
        let proxy = makeProxy()
        let decision = await proxy.decideRoute(path: "/v1/embeddings", body: Data(), headers: [:])
        guard case .local = decision else {
            XCTFail("expected .local, got \(decision)")
            return
        }
    }

    func testDecideRouteNonChatPathWithNoBackendIsNoCapableDevice() async {
        let proxy = makeProxy(backendBaseUrl: nil)
        let decision = await proxy.decideRoute(path: "/v1/embeddings", body: Data(), headers: [:])
        guard case .noCapableDevice = decision else {
            XCTFail("expected .noCapableDevice, got \(decision)")
            return
        }
    }

    func testDecideRouteOffloadDisabledIsLocal() async {
        let proxy = makeProxy(offloadEnabled: false)
        let body = Data(#"{"model":"m","stream":false}"#.utf8)
        let decision = await proxy.decideRoute(path: "/v1/chat/completions", body: body, headers: [:])
        guard case .local = decision else {
            XCTFail("expected .local with offload disabled, got \(decision)")
            return
        }
    }

    func testDecideRouteNeverHeaderForcesLocal() async {
        let proxy = makeProxy(peers: [makePeer(deviceId: "p", capability: ["m": 100.0])])
        let body = Data(#"{"model":"m"}"#.utf8)
        let decision = await proxy.decideRoute(
            path: "/v1/chat/completions",
            body: body,
            headers: ["x-dvai-offload": "never"]
        )
        guard case .local = decision else {
            XCTFail("expected .local under X-DVAI-Offload: never, got \(decision)")
            return
        }
    }

    func testDecideRoutePreferRoutesToCapablePeer() async {
        let proxy = makeProxy(peers: [makePeer(deviceId: "p", capability: ["m": 50.0])])
        let body = Data(#"{"model":"m"}"#.utf8)
        let decision = await proxy.decideRoute(
            path: "/v1/chat/completions",
            body: body,
            headers: [:]
        )
        switch decision {
        case .offload(_, let pid):
            XCTAssertEqual(pid, "p")
        default:
            XCTFail("expected .offload, got \(decision)")
        }
    }

    func testDecideRouteRequireWithoutPeersIsNoCapableDevice() async {
        let proxy = makeProxy()
        let body = Data(#"{"model":"m"}"#.utf8)
        let decision = await proxy.decideRoute(
            path: "/v1/chat/completions",
            body: body,
            headers: ["x-dvai-offload": "require"]
        )
        guard case .noCapableDevice = decision else {
            XCTFail("expected .noCapableDevice, got \(decision)")
            return
        }
    }
}
