using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace DVAIBridge.Shared.Hosting;

/// <summary>
/// v3.2 — pre-routing decision interface used by
/// <see cref="OpenAIServer"/>'s middleware. When the router returns
/// a non-null <see cref="OffloadResponse"/>, the server writes that
/// reply directly and skips the local route handlers; when it
/// returns null, the request falls through to local handling.
///
/// <see cref="OffloadRouter"/> is the canonical implementation; tests
/// (and unusual deployments) can supply their own.
/// </summary>
public interface IOffloadRouter
{
    /// <summary>
    /// Decide whether this request should be forwarded to a peer.
    /// </summary>
    /// <param name="path">Request path (e.g. "/v1/chat/completions").</param>
    /// <param name="body">Already-buffered request body.</param>
    /// <param name="headers">Request headers, case-insensitive map.</param>
    /// <param name="ct">Cancellation token tied to the consumer's request.</param>
    /// <returns>
    /// Non-null <see cref="OffloadResponse"/> to send back to the
    /// consumer (peer's reply); null to let the local handler serve.
    /// </returns>
    Task<OffloadResponse?> TryRouteAsync(
        string path,
        byte[] body,
        IReadOnlyDictionary<string, string> headers,
        CancellationToken ct);
}

/// <summary>
/// Pre-built peer descriptor consumed by <see cref="OffloadRouter"/>.
/// Same shape as the cross-platform <c>Peer</c> from the TS / Kotlin /
/// Swift codebases — only the fields the .NET routing path needs.
/// </summary>
public sealed record OffloadPeerInfo(
    string DeviceId,
    string BaseUrl,
    IReadOnlyDictionary<string, double> Capability,
    IReadOnlyList<string> LoadedModels);

/// <summary>
/// Pairing record looked up by <see cref="OffloadRouter"/> to HMAC-sign
/// forwarded requests. Mirrors the v3.0 <c>Pairing</c> shape.
/// </summary>
public sealed record OffloadPairing(string PeerDeviceId, string PairingKey);

/// <summary>
/// Reply forwarded back to the consumer when <see cref="IOffloadRouter"/>
/// chose to offload. The middleware writes <see cref="StatusCode"/> +
/// <see cref="Headers"/> + <see cref="Body"/> directly, bypassing the
/// local route handlers.
/// </summary>
public sealed record OffloadResponse(
    int StatusCode,
    IReadOnlyDictionary<string, string> Headers,
    byte[] Body);

/// <summary>
/// Canonical <see cref="IOffloadRouter"/>. Implements the same
/// decision logic the Android Ktor proxy + iOS Telegraph proxy + TS
/// forwarder use:
///
/// <list type="bullet">
/// <item>Honours the <c>X-DVAI-Offload</c> header
///   (<c>never</c> | <c>prefer</c> | <c>require</c>; default
///   <c>prefer</c>).</item>
/// <item>Picks the best peer for the requested model (peers with
///   the model already loaded preferred over higher-score peers
///   without it).</item>
/// <item>Forwards via <see cref="HttpClient"/> with HMAC-signed
///   identity headers (<c>X-DVAI-Peer-Device-Id</c>,
///   <c>X-DVAI-App-Id</c>, <c>X-DVAI-Nonce</c>,
///   <c>X-DVAI-Signature</c>).</item>
/// </list>
/// </summary>
public sealed class OffloadRouter : IOffloadRouter
{
    private static readonly HttpClient _client = new HttpClient
    {
        Timeout = TimeSpan.FromMinutes(10),
    };

    private readonly Func<IReadOnlyList<OffloadPeerInfo>> _peerProvider;
    private readonly Func<string, CancellationToken, Task<OffloadPairing?>> _pairingLookup;
    private readonly double _minLocalCapability;
    private readonly bool _enabled;
    private readonly bool _offloadOnlyMode;
    private readonly string _appId;
    private readonly string _selfDeviceId;

    /// <summary>Construct a router. See parameter docs for each lookup hook.</summary>
    /// <param name="enabled">Master switch — false makes <see cref="TryRouteAsync"/>
    ///   always return null (request falls through to local handler).</param>
    /// <param name="offloadOnlyMode">Set true when the SDK is in offload-only mode
    ///   (no local backend); changes how the "local" decision is reported.</param>
    /// <param name="minLocalCapability">Below this peer score the request stays local.</param>
    /// <param name="peerProvider">Live snapshot of discovered + paired peers.</param>
    /// <param name="pairingLookup">Find the pairing key for a peer device id (async; pairing
    ///   stores typically read off disk).</param>
    /// <param name="appId">This consumer app's identifier.</param>
    /// <param name="selfDeviceId">This device's stable identifier.</param>
    public OffloadRouter(
        bool enabled,
        bool offloadOnlyMode,
        double minLocalCapability,
        Func<IReadOnlyList<OffloadPeerInfo>> peerProvider,
        Func<string, CancellationToken, Task<OffloadPairing?>> pairingLookup,
        string appId,
        string selfDeviceId)
    {
        _enabled = enabled;
        _offloadOnlyMode = offloadOnlyMode;
        _minLocalCapability = minLocalCapability;
        _peerProvider = peerProvider ?? throw new ArgumentNullException(nameof(peerProvider));
        _pairingLookup = pairingLookup ?? throw new ArgumentNullException(nameof(pairingLookup));
        _appId = appId;
        _selfDeviceId = selfDeviceId;
    }

    /// <inheritdoc />
    public async Task<OffloadResponse?> TryRouteAsync(
        string path,
        byte[] body,
        IReadOnlyDictionary<string, string> headers,
        CancellationToken ct)
    {
        if (!_enabled) return null;

        var headerValue = "prefer";
        if (headers.TryGetValue("X-DVAI-Offload", out var h)) headerValue = h.ToLowerInvariant();

        if (headerValue == "never")
        {
            // Local forced — but if we have no backend, signal 503.
            return _offloadOnlyMode ? NoLocalBackendResponse() : null;
        }

        var modelId = ReadModelId(body);
        var peers = _peerProvider();
        var best = PickBestPeer(peers, modelId);

        if (headerValue == "require")
        {
            if (best is not null) return await ForwardAsync(best, path, body, headers, ct).ConfigureAwait(false);
            return NoCapableDeviceResponse();
        }

        // header == "prefer"
        if (best is not null && best.Score >= _minLocalCapability)
        {
            return await ForwardAsync(best, path, body, headers, ct).ConfigureAwait(false);
        }
        return _offloadOnlyMode ? NoCapableDeviceResponse() : null;
    }

    private sealed record RankedPeer(OffloadPeerInfo Peer, double Score, bool HasModel);

    private static RankedPeer? PickBestPeer(IReadOnlyList<OffloadPeerInfo> peers, string modelId)
    {
        return peers
            .Select(p => new RankedPeer(
                p,
                p.Capability.TryGetValue(modelId, out var s) ? s : 0,
                p.LoadedModels.Contains(modelId)))
            .Where(rp => rp.Score > 0)
            .OrderByDescending(rp => rp.HasModel)
            .ThenByDescending(rp => rp.Score)
            .FirstOrDefault();
    }

    private async Task<OffloadResponse> ForwardAsync(
        RankedPeer best,
        string path,
        byte[] body,
        IReadOnlyDictionary<string, string> headers,
        CancellationToken ct)
    {
        var basePath = path.StartsWith("/v1", StringComparison.Ordinal) ? path : "/v1" + path;
        var target = best.Peer.BaseUrl.TrimEnd('/') + basePath;

        var pairing = await _pairingLookup(best.Peer.DeviceId, ct).ConfigureAwait(false);
        using var req = new HttpRequestMessage(HttpMethod.Post, target);
        req.Content = new ByteArrayContent(body);
        req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");

        // Pass through non-hop-by-hop headers from the consumer.
        foreach (var (k, v) in headers)
        {
            var lk = k.ToLowerInvariant();
            if (lk is "host" or "content-length" or "connection" or "keep-alive"
                or "transfer-encoding" or "upgrade" or "te" or "trailers"
                or "proxy-authenticate" or "proxy-authorization" or "content-type")
            {
                continue;
            }
            req.Headers.TryAddWithoutValidation(k, v);
        }

        if (pairing is not null)
        {
            // v3.2.1 — route through DVAIBridge.Pairing.PairingHandshake
            // helpers (which already match the TS reference byte-for-byte)
            // instead of the local SignCanonical/NewNonce. The local
            // helpers had three protocol bugs vs the Hub's verifier:
            //   - canonical msg order: TS uses
            //       `nonce\nMETHOD\npath\nsha256hex(body)`;
            //     local used `METHOD\npath\nnonce\nbody-bytes`.
            //   - pairingKey encoding: TS decodes base64-url; local
            //     used raw UTF-8 bytes.
            //   - signature encoding: TS produces base64-url; local
            //     emitted hex.
            // Same fix iOS got in commit 5292482; mobile + .NET were
            // both running the wrong format and getting 401 from the
            // Hub on every signed request.
            var nonce = global::DVAIBridge.Pairing.PairingHandshake.GenerateNonce();
            var bodyString = body.Length == 0 ? null : System.Text.Encoding.UTF8.GetString(body);
            var canonical = global::DVAIBridge.Pairing.PairingHandshake.ComposeSignedMessage(
                nonce, "POST", new Uri(target).AbsolutePath, bodyString);
            var sig = global::DVAIBridge.Pairing.PairingHandshake.SignHmac(pairing.PairingKey, canonical);
            req.Headers.TryAddWithoutValidation("X-DVAI-Peer-Device-Id", _selfDeviceId);
            req.Headers.TryAddWithoutValidation("X-DVAI-App-Id", _appId);
            req.Headers.TryAddWithoutValidation("X-DVAI-Nonce", nonce);
            req.Headers.TryAddWithoutValidation("X-DVAI-Signature", sig);
            req.Headers.TryAddWithoutValidation("X-DVAI-Forwarded", "1");
        }

        try
        {
            using var resp = await _client.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct)
                .ConfigureAwait(false);
            var bytes = await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            var outHeaders = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var h in resp.Headers)
            {
                outHeaders[h.Key] = string.Join(", ", h.Value);
            }
            foreach (var h in resp.Content.Headers)
            {
                if (string.Equals(h.Key, "Content-Length", StringComparison.OrdinalIgnoreCase)) continue;
                outHeaders[h.Key] = string.Join(", ", h.Value);
            }
            return new OffloadResponse((int)resp.StatusCode, outHeaders, bytes);
        }
        catch (Exception ex)
        {
            var json = $"{{\"error\":{{\"type\":\"peer_unreachable\",\"code\":502,\"message\":\"{Escape(ex.Message)}\",\"peerId\":\"{best.Peer.DeviceId}\"}}}}";
            return JsonResponse(502, json);
        }
    }

    private static string ReadModelId(byte[] body)
    {
        if (body.Length == 0) return "";
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("model", out var m) && m.ValueKind == JsonValueKind.String)
            {
                return m.GetString() ?? "";
            }
        }
        catch (JsonException) { }
        return "";
    }

    // v3.2.1 — `SignCanonical` and `NewNonce` deleted. Signing now
    // routes through `DVAIBridge.Pairing.PairingHandshake` which
    // matches the TS canonical reference byte-for-byte. Keeping a
    // duplicate implementation here is what caused the silent 401
    // bug — the two drifted (wrong canonical order, wrong key
    // encoding, wrong sig encoding).

    private static OffloadResponse NoLocalBackendResponse() => JsonResponse(503,
        "{\"error\":{\"type\":\"no_local_backend\",\"code\":503,\"message\":\"DVAI is in offload-only mode and no peer is available.\"}}");

    private OffloadResponse NoCapableDeviceResponse() => JsonResponse(503,
        $"{{\"error\":{{\"type\":\"no_capable_device\",\"code\":503,\"message\":\"No device with capability >= {_minLocalCapability} tok/s available.\",\"localCapability\":0,\"requiredAtLeast\":{_minLocalCapability}}}}}");

    private static OffloadResponse JsonResponse(int code, string json) => new OffloadResponse(
        code,
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["Content-Type"] = "application/json" },
        Encoding.UTF8.GetBytes(json));

    private static string Escape(string s) =>
        s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "\\r");
}
