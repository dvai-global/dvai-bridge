namespace DVAIBridge;

/// <summary>
/// Result of a successful <see cref="DVAIBridge.DownloadModelAsync(DownloadOptions, System.Threading.CancellationToken)"/>.
/// </summary>
/// <param name="Path">
/// Absolute on-disk path. Pass this to a subsequent
/// <see cref="StartOptions.ModelPath"/>.
/// </param>
/// <param name="Sha256">Hex-encoded SHA-256 of the downloaded file (matches <see cref="DownloadOptions.Sha256"/>).</param>
/// <param name="SizeBytes">File size in bytes.</param>
public sealed record DownloadResult(
    string Path,
    string Sha256,
    long SizeBytes);
