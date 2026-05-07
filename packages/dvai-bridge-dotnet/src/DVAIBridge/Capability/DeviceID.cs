using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace DVAIBridge.Capability;

/// <summary>
/// Stable per-install device identifier. Generated once on first call,
/// persisted to the local-app-data dir alongside the capability cache.
///
/// <para>
/// Used to identify THIS device in mDNS TXT records (LAN discovery), in
/// rendezvous-server pairing payloads, and as a key in the capability
/// cache. NOT a privacy hazard: per-install and per-device-storage,
/// never tied to user identity. Reinstalling the app or wiping app
/// storage produces a fresh ID — that's the right behaviour.
/// </para>
/// </summary>
public static class DeviceId
{
    private const string FileName = "device-id.txt";
    private static readonly object _lock = new();
    private static string? _cached;

    /// <summary>
    /// Resolve the per-install device ID. Generates and persists a fresh
    /// ID on first call. Returns the same value across all subsequent
    /// calls in the same process and across process restarts (until the
    /// underlying file is removed).
    /// </summary>
    /// <param name="rootDir">
    /// Optional override for the dvai-bridge LocalAppData directory —
    /// used by tests for isolation. Production callers omit this and let
    /// the helper resolve <see cref="Environment.SpecialFolder.LocalApplicationData"/>.
    /// </param>
    public static string Resolve(string? rootDir = null)
    {
        lock (_lock)
        {
            if (rootDir is null && _cached is { } c)
            {
                return c;
            }

            var dir = rootDir ?? DefaultDir();
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, FileName);

            if (File.Exists(path))
            {
                var existing = File.ReadAllText(path).Trim();
                if (!string.IsNullOrEmpty(existing))
                {
                    if (rootDir is null) _cached = existing;
                    return existing;
                }
            }

            var fresh = Generate();
            File.WriteAllText(path, fresh);
            if (rootDir is null) _cached = fresh;
            return fresh;
        }
    }

    /// <summary>
    /// Default dvai-bridge LocalAppData directory:
    /// <c>{LocalApplicationData}/dvai-bridge</c>.
    /// </summary>
    public static string DefaultDir() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "dvai-bridge");

    /// <summary>
    /// Generate a fresh 22-char URL-safe random ID. Uses
    /// <see cref="RandomNumberGenerator"/> for cryptographic-grade
    /// randomness — same security profile as the TypeScript
    /// <c>generateDeviceId()</c> helper using WebCrypto.
    /// </summary>
    public static string Generate()
    {
        var bytes = new byte[16];
        RandomNumberGenerator.Fill(bytes);
        return Base64UrlEncode(bytes);
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

    /// <summary>Test-only reset of the cached ID. Not for production use.</summary>
    internal static void ResetForTests()
    {
        lock (_lock) { _cached = null; }
    }
}
