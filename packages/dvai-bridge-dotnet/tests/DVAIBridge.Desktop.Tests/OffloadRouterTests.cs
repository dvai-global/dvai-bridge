using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.Shared.Hosting;
using Xunit;

namespace DVAIBridge.Tests;

/// <summary>
/// v3.2 — pre-routing decision logic on .NET (xUnit parallel to
/// Android's OffloadProxyDecisionTest.kt and iOS
/// OffloadProxyDecisionTests.swift). Constructs an
/// <see cref="OffloadRouter"/> with synthetic peer + pairing
/// providers and exercises <c>TryRouteAsync</c> directly. No real
/// HTTP, no Kestrel — fast, deterministic.
/// </summary>
public class OffloadRouterTests
{
    private static readonly IReadOnlyDictionary<string, string> EmptyHeaders =
        new Dictionary<string, string>();

    private static OffloadRouter MakeRouter(
        bool enabled = true,
        bool offloadOnlyMode = false,
        double minLocalCapability = 10.0,
        IReadOnlyList<OffloadPeerInfo>? peers = null) =>
        new OffloadRouter(
            enabled: enabled,
            offloadOnlyMode: offloadOnlyMode,
            minLocalCapability: minLocalCapability,
            peerProvider: () => peers ?? new List<OffloadPeerInfo>(),
            pairingLookup: (peerId, ct) =>
                Task.FromResult<OffloadPairing?>(new OffloadPairing(peerId, "vGzn8h_FNHkqL5Q1tN-rTu3pYWB7K0vGzn8h_FNHkqI")),
            appId: "test.app",
            selfDeviceId: "test-self-device");

    private static OffloadPeerInfo Peer(
        string deviceId,
        Dictionary<string, double> capability,
        IReadOnlyList<string>? loadedModels = null,
        string baseUrl = "http://127.0.0.1:1") =>
        new OffloadPeerInfo(
            DeviceId: deviceId,
            BaseUrl: baseUrl,
            Capability: capability,
            LoadedModels: loadedModels ?? new List<string>());

    private static IReadOnlyDictionary<string, string> Headers(params (string K, string V)[] kv)
    {
        var d = new Dictionary<string, string>(System.StringComparer.OrdinalIgnoreCase);
        foreach (var (k, v) in kv) d[k] = v;
        return d;
    }

    private static byte[] ChatBody(string model = "model-a") =>
        Encoding.UTF8.GetBytes($"{{\"model\":\"{model}\",\"stream\":false}}");

    /* --------------------------------------------------------------- */
    /* Disabled / no-peer paths                                        */
    /* --------------------------------------------------------------- */

    [Fact]
    public async Task TryRoute_DisabledRouter_ReturnsNull()
    {
        var router = MakeRouter(enabled: false);
        var rsp = await router.TryRouteAsync("/v1/chat/completions", ChatBody(), EmptyHeaders, CancellationToken.None);
        Assert.Null(rsp);
    }

    [Fact]
    public async Task TryRoute_NoPeers_StaysLocal()
    {
        var router = MakeRouter(peers: new List<OffloadPeerInfo>());
        var rsp = await router.TryRouteAsync("/v1/chat/completions", ChatBody(), EmptyHeaders, CancellationToken.None);
        Assert.Null(rsp);
    }

    [Fact]
    public async Task TryRoute_NoPeers_OffloadOnlyMode_Returns503()
    {
        var router = MakeRouter(offloadOnlyMode: true, peers: new List<OffloadPeerInfo>());
        var rsp = await router.TryRouteAsync("/v1/chat/completions", ChatBody(), EmptyHeaders, CancellationToken.None);
        Assert.NotNull(rsp);
        Assert.Equal(503, rsp!.StatusCode);
        var body = Encoding.UTF8.GetString(rsp.Body);
        Assert.Contains("no_capable_device", body);
    }

    /* --------------------------------------------------------------- */
    /* X-DVAI-Offload header                                           */
    /* --------------------------------------------------------------- */

    [Fact]
    public async Task TryRoute_HeaderNever_StaysLocal()
    {
        var router = MakeRouter(peers: new[] { Peer("p", new() { ["model-a"] = 50.0 }) });
        var rsp = await router.TryRouteAsync(
            "/v1/chat/completions",
            ChatBody(),
            Headers(("X-DVAI-Offload", "never")),
            CancellationToken.None);
        Assert.Null(rsp); // peer would qualify, but never forces local.
    }

    [Fact]
    public async Task TryRoute_HeaderNever_OffloadOnly_Returns503NoLocalBackend()
    {
        var router = MakeRouter(offloadOnlyMode: true, peers: new[] { Peer("p", new() { ["model-a"] = 50.0 }) });
        var rsp = await router.TryRouteAsync(
            "/v1/chat/completions",
            ChatBody(),
            Headers(("X-DVAI-Offload", "never")),
            CancellationToken.None);
        Assert.NotNull(rsp);
        Assert.Equal(503, rsp!.StatusCode);
        Assert.Contains("no_local_backend", Encoding.UTF8.GetString(rsp.Body));
    }

    [Fact]
    public async Task TryRoute_HeaderRequire_NoCapablePeer_Returns503()
    {
        // Peer has the model but too-low score; require=true insists on offload regardless.
        // PickBestPeer still returns it (we only filter score==0). So this routes to peer.
        // To test "no capable device", use peers that don't have the model at all.
        var router = MakeRouter(peers: new[] { Peer("p", new() { ["other-model"] = 100.0 }) });
        var rsp = await router.TryRouteAsync(
            "/v1/chat/completions",
            ChatBody("model-a"),
            Headers(("X-DVAI-Offload", "require")),
            CancellationToken.None);
        Assert.NotNull(rsp);
        Assert.Equal(503, rsp!.StatusCode);
        Assert.Contains("no_capable_device", Encoding.UTF8.GetString(rsp.Body));
    }

    /* --------------------------------------------------------------- */
    /* Score threshold ("prefer")                                       */
    /* --------------------------------------------------------------- */

    [Fact]
    public async Task TryRoute_PreferDefault_PeerBelowThreshold_StaysLocal()
    {
        // minLocalCapability = 10.0. Peer score 5.0 < 10.0 ⇒ stay local.
        var router = MakeRouter(minLocalCapability: 10.0,
            peers: new[] { Peer("p", new() { ["model-a"] = 5.0 }) });
        var rsp = await router.TryRouteAsync(
            "/v1/chat/completions",
            ChatBody(),
            EmptyHeaders,
            CancellationToken.None);
        Assert.Null(rsp);
    }

    [Fact]
    public async Task TryRoute_PreferDefault_PeerAboveThreshold_ForwardsAndGets502()
    {
        // Peer score 50.0 ≥ 10.0 → router forwards to peer.BaseUrl. Since
        // baseUrl is fake (127.0.0.1:1), HttpClient fails with a connection
        // error. The router catches and returns a 502 peer_unreachable.
        // That 502 IS the proof that the router selected this peer.
        var router = MakeRouter(minLocalCapability: 10.0,
            peers: new[] { Peer("p", new() { ["model-a"] = 50.0 }, baseUrl: "http://127.0.0.1:1") });
        var rsp = await router.TryRouteAsync(
            "/v1/chat/completions",
            ChatBody(),
            EmptyHeaders,
            CancellationToken.None);
        Assert.NotNull(rsp);
        Assert.Equal(502, rsp!.StatusCode);
        var body = Encoding.UTF8.GetString(rsp.Body);
        Assert.Contains("peer_unreachable", body);
        Assert.Contains("\"peerId\":\"p\"", body);
    }

    [Fact]
    public async Task TryRoute_PickBestPeer_PrefersLoadedModelOverHigherScore()
    {
        // Higher score peer "h" has model-a at 50.0 but it's NOT loaded.
        // Lower score peer "l" has model-a at 20.0 and it IS loaded.
        // Router should pick "l" (loaded > score).
        var router = MakeRouter(minLocalCapability: 10.0, peers: new[]
        {
            Peer("h", new() { ["model-a"] = 50.0 }, baseUrl: "http://127.0.0.1:1"),
            Peer("l", new() { ["model-a"] = 20.0 }, loadedModels: new[] { "model-a" }, baseUrl: "http://127.0.0.1:2"),
        });
        var rsp = await router.TryRouteAsync(
            "/v1/chat/completions",
            ChatBody(),
            EmptyHeaders,
            CancellationToken.None);
        Assert.NotNull(rsp);
        // 502 (since 127.0.0.1:2 is also unreachable), but the peerId in the
        // error body proves which peer was selected.
        Assert.Equal(502, rsp!.StatusCode);
        Assert.Contains("\"peerId\":\"l\"", Encoding.UTF8.GetString(rsp.Body));
    }

    [Fact]
    public async Task TryRoute_PickBestPeer_SkipsZeroScorePeers()
    {
        // No peer has a non-zero score for model-a. Router falls through.
        var router = MakeRouter(minLocalCapability: 10.0, peers: new[]
        {
            Peer("a", new() { ["other"] = 100.0 }),
            Peer("b", new() { ["model-a"] = 0.0 }),
        });
        var rsp = await router.TryRouteAsync(
            "/v1/chat/completions",
            ChatBody(),
            EmptyHeaders,
            CancellationToken.None);
        Assert.Null(rsp);
    }

    /* --------------------------------------------------------------- */
    /* Body parsing                                                    */
    /* --------------------------------------------------------------- */

    [Fact]
    public async Task TryRoute_EmptyBody_TreatsModelAsEmpty()
    {
        // Empty body -> modelId "". No peer scores "" > 0 (unless explicitly
        // configured), so we fall through to local.
        var router = MakeRouter(peers: new[] { Peer("p", new() { ["real-model"] = 50.0 }) });
        var rsp = await router.TryRouteAsync(
            "/v1/chat/completions",
            new byte[0],
            EmptyHeaders,
            CancellationToken.None);
        Assert.Null(rsp);
    }

    [Fact]
    public async Task TryRoute_MalformedJson_TreatsModelAsEmpty()
    {
        var router = MakeRouter(peers: new[] { Peer("p", new() { ["real-model"] = 50.0 }) });
        var rsp = await router.TryRouteAsync(
            "/v1/chat/completions",
            Encoding.UTF8.GetBytes("not valid json"),
            EmptyHeaders,
            CancellationToken.None);
        Assert.Null(rsp);
    }
}
