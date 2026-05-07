using System;
using System.Security.Cryptography;
using System.Text;

namespace DVAIBridge.Pairing;

/// <summary>
/// HMAC-SHA256 helpers for the LAN-pairing handshake. Mirrors the TS
/// implementation in <c>@dvai-bridge/core/src/pairing/handshake.ts</c>:
/// canonical message format, base64-url encoding, lowercase-hex SHA-256
/// body hashing.
///
/// <para>
/// The first time Device A wants to offload to Device B over the LAN, A
/// POSTs <c>/v1/dvai/handshake</c> to B with its identity + a fresh
/// nonce. B surfaces a UI prompt to the user; on approve, B generates a
/// 256-bit pairing key and returns it. From then on, A includes
/// <c>X-DVAI-Pairing: HMAC-SHA256(pairingKey, canonicalMessage)</c> on
/// every offload request to B.
/// </para>
/// </summary>
public static class PairingHandshake
{
    private const string EmptyBodyHash =
        "0000000000000000000000000000000000000000000000000000000000000000";

    /// <summary>Generate a fresh 256-bit pairing key (base64-url encoded).</summary>
    public static string GeneratePairingKey()
    {
        var bytes = new byte[32];
        RandomNumberGenerator.Fill(bytes);
        return Base64UrlEncode(bytes);
    }

    /// <summary>Generate a fresh nonce (128 bits, base64-url encoded).</summary>
    public static string GenerateNonce()
    {
        var bytes = new byte[16];
        RandomNumberGenerator.Fill(bytes);
        return Base64UrlEncode(bytes);
    }

    /// <summary>
    /// Compose the canonical message that gets HMAC-signed for a peer-to-peer
    /// offload request. The peer recomputes the same string and verifies.
    ///
    /// Format: <c>{nonce}\n{METHOD}\n{path}\n{bodyHash}</c> — bodyHash is
    /// the lowercase-hex SHA-256 of the request body bytes (or 64 zeros
    /// for an empty body).
    /// </summary>
    public static string ComposeSignedMessage(string nonce, string method, string path, string? body)
    {
        if (nonce is null) throw new ArgumentNullException(nameof(nonce));
        if (method is null) throw new ArgumentNullException(nameof(method));
        if (path is null) throw new ArgumentNullException(nameof(path));

        var bodyHash = string.IsNullOrEmpty(body) ? EmptyBodyHash : Sha256Hex(body!);
        return $"{nonce}\n{method.ToUpperInvariant()}\n{path}\n{bodyHash}";
    }

    /// <summary>
    /// HMAC-SHA256(pairingKey, message). Returns the base64-url encoded
    /// signature suitable for the <c>X-DVAI-Pairing</c> header.
    /// </summary>
    public static string SignHmac(string pairingKey, string message)
    {
        if (pairingKey is null) throw new ArgumentNullException(nameof(pairingKey));
        if (message is null) throw new ArgumentNullException(nameof(message));

        var keyBytes = Base64UrlDecode(pairingKey);
        using var hmac = new HMACSHA256(keyBytes);
        var sig = hmac.ComputeHash(Encoding.UTF8.GetBytes(message));
        return Base64UrlEncode(sig);
    }

    /// <summary>
    /// Verify an HMAC. Constant-time comparison after recomputing the
    /// expected signature.
    /// </summary>
    public static bool VerifyHmac(string pairingKey, string message, string signature)
    {
        var expected = SignHmac(pairingKey, message);
        return CryptographicOperations.FixedTimeEquals(
            Encoding.ASCII.GetBytes(expected),
            Encoding.ASCII.GetBytes(signature));
    }

    private static string Sha256Hex(string input)
    {
        var bytes = Encoding.UTF8.GetBytes(input);
        var hash = SHA256.HashData(bytes);
        var sb = new StringBuilder(hash.Length * 2);
        foreach (var b in hash) sb.Append(b.ToString("x2"));
        return sb.ToString();
    }

    private static string Base64UrlEncode(byte[] bytes)
    {
        var b64 = Convert.ToBase64String(bytes);
        var sb = new StringBuilder(b64.Length);
        foreach (var ch in b64)
        {
            switch (ch)
            {
                case '+': sb.Append('-'); break;
                case '/': sb.Append('_'); break;
                case '=': break;
                default: sb.Append(ch); break;
            }
        }
        return sb.ToString();
    }

    private static byte[] Base64UrlDecode(string s)
    {
        var b64 = s.Replace('-', '+').Replace('_', '/');
        var pad = (4 - (b64.Length % 4)) % 4;
        if (pad > 0) b64 += new string('=', pad);
        return Convert.FromBase64String(b64);
    }
}
