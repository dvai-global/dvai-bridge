using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.Capability;

namespace DVAIBridge.Pairing;

/// <summary>
/// Persistent JSON-backed pairing store. Lives at
/// <c>{LocalApplicationData}/dvai-bridge/pairings.json</c> by default.
/// Mirrors the TypeScript <c>NodeFsPairingStore</c> shape so pairing
/// data is portable across runtimes.
/// </summary>
public sealed class PairingStore
{
    private const string FileName = "pairings.json";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly string _path;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private Dictionary<string, Pairing>? _cache;

    /// <summary>
    /// Construct a store at the given JSON path. Production callers use
    /// <see cref="CreateDefault"/>; tests pass a tmpdir-rooted path.
    /// </summary>
    public PairingStore(string path)
    {
        _path = path ?? throw new ArgumentNullException(nameof(path));
    }

    /// <summary>
    /// Construct a store rooted at the platform default
    /// (<c>{LocalApplicationData}/dvai-bridge/pairings.json</c>).
    /// </summary>
    public static PairingStore CreateDefault() =>
        new(System.IO.Path.Combine(DeviceId.DefaultDir(), FileName));

    /// <summary>The on-disk path the store reads / writes.</summary>
    public string FilePath => _path;

    /// <summary>Look up a pairing by peer device ID. Returns <c>null</c> when missing.</summary>
    public async Task<Pairing?> GetAsync(string peerDeviceId, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await EnsureLoadedAsync(ct).ConfigureAwait(false);
            return _cache!.TryGetValue(peerDeviceId, out var p) ? p : null;
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>Persist a pairing (overwrites the previous entry for the same peer).</summary>
    public async Task SetAsync(Pairing pairing, CancellationToken ct = default)
    {
        if (pairing is null) throw new ArgumentNullException(nameof(pairing));
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await EnsureLoadedAsync(ct).ConfigureAwait(false);
            _cache![pairing.PeerDeviceId] = pairing;
            await SaveAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>Snapshot the full pairing list.</summary>
    public async Task<IReadOnlyList<Pairing>> ListAsync(CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await EnsureLoadedAsync(ct).ConfigureAwait(false);
            return _cache!.Values.ToList();
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>Remove a pairing — peer must re-handshake to reconnect.</summary>
    public async Task RemoveAsync(string peerDeviceId, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await EnsureLoadedAsync(ct).ConfigureAwait(false);
            if (_cache!.Remove(peerDeviceId))
            {
                await SaveAsync(ct).ConfigureAwait(false);
            }
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>Drop every pairing — both in-memory and on disk.</summary>
    public async Task ClearAsync(CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            _cache = new Dictionary<string, Pairing>();
            await SaveAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    private async Task EnsureLoadedAsync(CancellationToken ct)
    {
        if (_cache is not null) return;

        if (!File.Exists(_path))
        {
            _cache = new Dictionary<string, Pairing>();
            return;
        }

        try
        {
            await using var fs = File.OpenRead(_path);
            var entries = await JsonSerializer
                .DeserializeAsync<Dictionary<string, Pairing>>(fs, JsonOptions, ct)
                .ConfigureAwait(false);
            _cache = entries ?? new Dictionary<string, Pairing>();
        }
        catch (JsonException)
        {
            _cache = new Dictionary<string, Pairing>();
        }
    }

    private async Task SaveAsync(CancellationToken ct)
    {
        if (_cache is null) return;
        var dir = System.IO.Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        await using var fs = File.Create(_path);
        await JsonSerializer.SerializeAsync(fs, _cache, JsonOptions, ct).ConfigureAwait(false);
    }
}
