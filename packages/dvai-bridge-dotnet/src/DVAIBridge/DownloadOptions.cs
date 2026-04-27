namespace DVAIBridge;

/// <summary>
/// Options for <see cref="DVAIBridge.DownloadModelAsync(DownloadOptions, System.Threading.CancellationToken)"/>.
/// Wraps the per-platform <c>ModelDownloader</c>'s resumable HTTP-Range
/// + sha256-verifying download flow.
/// </summary>
/// <param name="Url">
/// The HTTP(S) URL to fetch. Must be a stable, deterministic location —
/// the downloader uses ETag + Range resumption.
/// </param>
/// <param name="Sha256">
/// Hex-encoded SHA-256 expected for the fully-downloaded file. The
/// downloader rejects mismatches with
/// <see cref="DVAIBridgeErrorKind.ChecksumMismatch"/>.
/// </param>
/// <param name="DestFilename">
/// Optional filename override under the platform's models cache directory.
/// Defaults to the URL's last path component.
/// </param>
public sealed record DownloadOptions(
    string Url,
    string Sha256,
    string? DestFilename = null);
