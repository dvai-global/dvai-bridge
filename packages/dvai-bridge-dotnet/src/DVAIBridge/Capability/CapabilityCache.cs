using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace DVAIBridge.Capability;

/// <summary>
/// Persistent cache of <see cref="CapabilityScore"/> entries, keyed by
/// (modelId, libraryVersion). Backed by a single JSON file under
/// <c>{LocalApplicationData}/dvai-bridge/capability.json</c>.
///
/// <para>
/// Mirrors the shape of the TypeScript <c>NodeFsCapabilityCache</c> — same
/// JSON structure, so capability data is portable across runtimes
/// (e.g. an Electron host can read the same file the Avalonia host
/// wrote).
/// </para>
///
/// <para>
/// Thread-safe: a single async lock serializes file I/O. The in-memory
/// dictionary acts as a read-through cache.
/// </para>
/// </summary>
public sealed class CapabilityCache
{
    private const string FileName = "capability.json";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly string _path;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private Dictionary<string, CapabilityScore>? _cache;

    /// <summary>
    /// Construct a cache at the given JSON path. Production callers use
    /// <see cref="CreateDefault"/>; tests pass a tmpdir-rooted path.
    /// </summary>
    public CapabilityCache(string path)
    {
        _path = path ?? throw new ArgumentNullException(nameof(path));
    }

    /// <summary>
    /// Construct a cache rooted at the platform default
    /// (<c>{LocalApplicationData}/dvai-bridge/capability.json</c>).
    /// </summary>
    public static CapabilityCache CreateDefault() =>
        new(System.IO.Path.Combine(DeviceId.DefaultDir(), FileName));

    /// <summary>The on-disk path the cache reads / writes.</summary>
    public string FilePath => _path;

    /// <summary>
    /// Look up a cached score by (modelId, libraryVersion). Returns
    /// <c>null</c> when the cache has no matching entry.
    /// </summary>
    public async Task<CapabilityScore?> GetAsync(string modelId, string libraryVersion, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await EnsureLoadedAsync(ct).ConfigureAwait(false);
            return _cache!.TryGetValue(KeyOf(modelId, libraryVersion), out var s) ? s : null;
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>Persist a fresh capability score (overwrites by key).</summary>
    public async Task SetAsync(CapabilityScore score, CancellationToken ct = default)
    {
        if (score is null) throw new ArgumentNullException(nameof(score));
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await EnsureLoadedAsync(ct).ConfigureAwait(false);
            _cache![KeyOf(score.ModelId, score.LibraryVersion)] = score;
            await SaveAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>Snapshot the full cache contents.</summary>
    public async Task<IReadOnlyList<CapabilityScore>> ListAsync(CancellationToken ct = default)
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

    /// <summary>Drop every cached entry — both in-memory and on disk.</summary>
    public async Task ClearAsync(CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            _cache = new Dictionary<string, CapabilityScore>();
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
            _cache = new Dictionary<string, CapabilityScore>();
            return;
        }

        try
        {
            await using var fs = File.OpenRead(_path);
            var entries = await JsonSerializer
                .DeserializeAsync<Dictionary<string, CapabilityScore>>(fs, JsonOptions, ct)
                .ConfigureAwait(false);
            _cache = entries ?? new Dictionary<string, CapabilityScore>();
        }
        catch (JsonException)
        {
            // Corrupted on-disk JSON shouldn't crash the bridge — start fresh.
            _cache = new Dictionary<string, CapabilityScore>();
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

    private static string KeyOf(string modelId, string libraryVersion) =>
        $"{modelId}@{libraryVersion}";
}
