using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.Shared.Hosting;
using Xunit;

namespace DVAIBridge.Tests;

/// <summary>
/// v3.2.x — full-loop integration tests for <see cref="OffloadRouter"/>
/// (.NET parallel to Android's <c>OffloadProxyForwardingTest.kt</c>).
///
/// Spins up a real <see cref="HttpListener"/> as a stand-in peer, has
/// the router forward to it, and asserts:
///
///   - The request method + path landed at the peer.
///   - Body bytes forwarded unchanged.
///   - HMAC identity headers (<c>X-DVAI-Peer-Device-Id</c> /
///     <c>X-DVAI-App-Id</c> / <c>X-DVAI-Nonce</c> /
///     <c>X-DVAI-Signature</c>) are present.
///   - The signature verifies against the pairing key + canonical
///     <c>METHOD\nPATH\nNONCE\nbody</c> string — same canonicalisation
///     the Android Ktor proxy + iOS OffloadProxy + TS forwarder use.
///   - The peer's response status / headers / body propagate back to
///     the consumer untouched.
/// </summary>
public class OffloadRouterForwardingTests : IAsyncLifetime
{
    // Base64-url-encoded 256-bit pairing key (matches the v3.2.1 wire
    // format — `PairingHandshake.SignHmac` decodes the key as
    // base64-url before HMAC-keying). Generated once with
    // `[byte[]] new byte[32] |% { Base64UrlEncode($_) }`; constant
    // string here keeps the test deterministic.
    private const string PairingKey = "vGzn8h_FNHkqL5Q1tN-rTu3pYWB7K0vGzn8h_FNHkqI";
    private const string PeerDeviceId = "peer-1";
    private const string SelfDeviceId = "self-1";
    private const string AppId = "test.app";

    private HttpListener _peer = null!;
    private string _peerBaseUrl = null!;
    private readonly ConcurrentQueue<RecordedRequest> _peerRequests = new();
    private CancellationTokenSource _peerLoopCts = new();
    private Task _peerLoopTask = Task.CompletedTask;

    /// <summary>What the peer should reply with for the next request.</summary>
    private (int status, byte[] body, string contentType) _peerReply =
        (200, Encoding.UTF8.GetBytes("{\"served_by\":\"peer\"}"), "application/json");

    public async Task InitializeAsync()
    {
        // Pick a free loopback port for the peer.
        int port = GetFreeLoopbackPort();
        _peerBaseUrl = $"http://127.0.0.1:{port}";
        _peer = new HttpListener();
        _peer.Prefixes.Add(_peerBaseUrl + "/");
        _peer.Start();

        _peerLoopTask = Task.Run(async () =>
        {
            while (!_peerLoopCts.IsCancellationRequested)
            {
                HttpListenerContext ctx;
                try
                {
                    ctx = await _peer.GetContextAsync().ConfigureAwait(false);
                }
                catch (HttpListenerException) { break; }
                catch (ObjectDisposedException) { break; }

                try
                {
                    using var ms = new MemoryStream();
                    await ctx.Request.InputStream.CopyToAsync(ms).ConfigureAwait(false);
                    var body = ms.ToArray();

                    var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    foreach (string? k in ctx.Request.Headers.AllKeys)
                    {
                        if (k is null) continue;
                        headers[k] = ctx.Request.Headers[k] ?? "";
                    }
                    _peerRequests.Enqueue(new RecordedRequest(
                        Method: ctx.Request.HttpMethod,
                        Path: ctx.Request.Url!.AbsolutePath,
                        Headers: headers,
                        Body: body));

                    var (status, replyBody, contentType) = _peerReply;
                    ctx.Response.StatusCode = status;
                    ctx.Response.ContentType = contentType;
                    ctx.Response.ContentLength64 = replyBody.Length;
                    ctx.Response.Headers["X-Custom-Peer-Header"] = "peer-says-hi";
                    await ctx.Response.OutputStream.WriteAsync(replyBody).ConfigureAwait(false);
                }
                finally { ctx.Response.Close(); }
            }
        });

        await Task.CompletedTask;
    }

    public Task DisposeAsync()
    {
        _peerLoopCts.Cancel();
        try { _peer.Stop(); } catch { /* best-effort */ }
        try { _peer.Close(); } catch { /* best-effort */ }
        return Task.CompletedTask;
    }

    private OffloadRouter MakeRouter(double minLocalCapability = 10.0) =>
        new OffloadRouter(
            enabled: true,
            offloadOnlyMode: false,
            minLocalCapability: minLocalCapability,
            peerProvider: () => new[]
            {
                new OffloadPeerInfo(
                    DeviceId: PeerDeviceId,
                    BaseUrl: _peerBaseUrl,
                    Capability: new Dictionary<string, double> { ["model-a"] = 50.0 },
                    LoadedModels: new[] { "model-a" }),
            },
            pairingLookup: (deviceId, _) =>
                Task.FromResult<OffloadPairing?>(new OffloadPairing(deviceId, PairingKey)),
            appId: AppId,
            selfDeviceId: SelfDeviceId);

    private static byte[] ChatBody(string model = "model-a") =>
        Encoding.UTF8.GetBytes($"{{\"model\":\"{model}\",\"stream\":false}}");

    [Fact]
    public async Task ForwardsChatCompletion_ToPeer_WithHmacSignedHeaders()
    {
        var router = MakeRouter();
        var body = ChatBody();

        var rsp = await router.TryRouteAsync(
            "/v1/chat/completions",
            body,
            new Dictionary<string, string> { ["X-Test-Header"] = "from-consumer" },
            CancellationToken.None);

        Assert.NotNull(rsp);
        Assert.Equal(200, rsp!.StatusCode);
        Assert.Contains("served_by", Encoding.UTF8.GetString(rsp.Body));

        // The peer's custom header should propagate back to the consumer.
        Assert.True(rsp.Headers.TryGetValue("X-Custom-Peer-Header", out var custom));
        Assert.Equal("peer-says-hi", custom);

        // Exactly one request landed at the peer.
        Assert.Single(_peerRequests);
        var rec = _peerRequests.TryPeek(out var r) ? r! : throw new Xunit.Sdk.XunitException("no recorded request");

        Assert.Equal("POST", rec.Method);
        Assert.Equal("/v1/chat/completions", rec.Path);
        Assert.Equal(body, rec.Body);

        // HMAC identity headers must all be present.
        Assert.Equal(SelfDeviceId, rec.Headers["X-DVAI-Peer-Device-Id"]);
        Assert.Equal(AppId, rec.Headers["X-DVAI-App-Id"]);
        Assert.True(rec.Headers.TryGetValue("X-DVAI-Nonce", out var nonce));
        Assert.False(string.IsNullOrEmpty(nonce));
        Assert.True(rec.Headers.TryGetValue("X-DVAI-Signature", out var sig));
        Assert.False(string.IsNullOrEmpty(sig));
        Assert.Equal("1", rec.Headers["X-DVAI-Forwarded"]);

        // And the consumer-supplied non-hop header must pass through.
        Assert.Equal("from-consumer", rec.Headers["X-Test-Header"]);

        // Verify the signature ourselves.
        var expected = ComputeSignature("POST", "/v1/chat/completions", body, nonce, PairingKey);
        Assert.Equal(expected, sig);
    }

    [Fact]
    public async Task ForwardsBodyByteForByte_NoMutation()
    {
        // The router parses `body` as JSON to extract `model` for peer
        // selection, so the body must be valid JSON AND a single object.
        // Beyond that we want to confirm the proxy doesn't re-encode /
        // re-serialise it: build a body with deliberate whitespace,
        // unicode escapes, and float precision the proxy must preserve.
        var json =
            "{\n" +
            "  \"model\": \"model-a\",\n" +
            "  \"messages\": [{\"role\":\"user\",\"content\":\"\\u4e2d\\u6587 \\ud83d\\ude00\"}],\n" +
            "  \"temperature\": 0.123456789012345,\n" +
            "  \"trailing_whitespace\":   \"keep-me\"  \n" +
            "}";
        var body = Encoding.UTF8.GetBytes(json);

        var router = MakeRouter();
        _ = await router.TryRouteAsync(
            "/v1/chat/completions", body, new Dictionary<string, string>(), CancellationToken.None);

        Assert.Single(_peerRequests);
        var rec = _peerRequests.TryPeek(out var r) ? r! : throw new Xunit.Sdk.XunitException("no recorded request");
        // Byte-for-byte equality — proves the proxy didn't re-serialise
        // (which would normalise whitespace + decode unicode escapes).
        Assert.Equal(body, rec.Body);
    }

    [Fact]
    public async Task PeerNonOkStatusPropagatesUnchanged()
    {
        // Have the peer reply with a 429 + JSON error body.
        _peerReply = (429,
            Encoding.UTF8.GetBytes("{\"error\":{\"type\":\"rate_limit\"}}"),
            "application/json");

        var router = MakeRouter();
        var rsp = await router.TryRouteAsync(
            "/v1/chat/completions", ChatBody(), new Dictionary<string, string>(), CancellationToken.None);

        Assert.NotNull(rsp);
        Assert.Equal(429, rsp!.StatusCode);
        Assert.Contains("rate_limit", Encoding.UTF8.GetString(rsp.Body));
    }

    [Fact]
    public async Task HopByHopHeadersStripped_OtherHeadersPassThrough()
    {
        var router = MakeRouter();
        _ = await router.TryRouteAsync(
            "/v1/chat/completions",
            ChatBody(),
            new Dictionary<string, string>
            {
                ["Connection"] = "keep-alive",   // hop-by-hop — must NOT forward
                ["Host"] = "should-be-rewritten", // hop-by-hop — must NOT forward
                ["Content-Length"] = "9999",     // hop-by-hop — must NOT forward
                ["Authorization"] = "Bearer abc", // end-to-end — MUST forward
                ["X-App-Custom"] = "yes",        // end-to-end — MUST forward
            },
            CancellationToken.None);

        var rec = _peerRequests.TryPeek(out var r) ? r! : throw new Xunit.Sdk.XunitException("no recorded request");
        // Hop-by-hop headers must NOT be propagated verbatim.
        Assert.False(rec.Headers.ContainsKey("Connection")
            || (rec.Headers.TryGetValue("Connection", out var c) && c == "keep-alive"),
            "Connection should not be propagated");
        Assert.NotEqual("should-be-rewritten",
            rec.Headers.TryGetValue("Host", out var h) ? h : "");
        // End-to-end headers must propagate.
        Assert.Equal("Bearer abc", rec.Headers["Authorization"]);
        Assert.Equal("yes", rec.Headers["X-App-Custom"]);
    }

    /// <summary>
    /// Independent oracle for the v3.2.1 canonical signing format —
    /// matches the TS reference (packages/dvai-bridge-core/src/pairing/
    /// handshake.ts) byte-for-byte. The test catches drift in the
    /// production canonicalisation by computing the expected signature
    /// here from primitives, NOT by calling the production
    /// <c>PairingHandshake</c> helpers (otherwise the test would
    /// tautologically pass against itself).
    ///
    /// Format: <c>{nonce}\n{METHOD}\n{path}\n{sha256hex(body)}</c>;
    /// pairingKey is base64-url decoded; signature is base64-url
    /// encoded.
    /// </summary>
    private static string ComputeSignature(string method, string path, byte[] body, string nonce, string key)
    {
        // sha256(body) → lowercase hex, OR all-zeros for empty body.
        string bodyHash;
        if (body.Length == 0)
        {
            bodyHash = new string('0', 64);
        }
        else
        {
            using var sha = SHA256.Create();
            bodyHash = Convert.ToHexString(sha.ComputeHash(body)).ToLowerInvariant();
        }
        var canonical = $"{nonce}\n{method.ToUpperInvariant()}\n{path}\n{bodyHash}";

        // Pairing key: base64-url decode (NOT raw UTF-8 bytes).
        var keyBytes = Base64UrlDecode(key);
        using var hmac = new HMACSHA256(keyBytes);
        var sig = hmac.ComputeHash(Encoding.UTF8.GetBytes(canonical));
        return Base64UrlEncode(sig);
    }

    private static string Base64UrlEncode(byte[] bytes)
    {
        return Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    private static byte[] Base64UrlDecode(string s)
    {
        var b64 = s.Replace('-', '+').Replace('_', '/');
        var pad = (4 - (b64.Length % 4)) % 4;
        return Convert.FromBase64String(b64 + new string('=', pad));
    }

    private static int GetFreeLoopbackPort()
    {
        // Bind a transient TCP listener on loopback:0 to let the OS pick
        // an unused port, capture it, and immediately release.
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private sealed record RecordedRequest(
        string Method,
        string Path,
        Dictionary<string, string> Headers,
        byte[] Body);
}
