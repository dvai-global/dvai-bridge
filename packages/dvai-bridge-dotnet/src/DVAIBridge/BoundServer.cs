namespace DVAIBridge;

/// <summary>
/// The bound, running HTTP server returned by
/// <see cref="DVAIBridge.StartAsync(StartOptions, System.Threading.CancellationToken)"/>.
/// </summary>
/// <param name="BaseUrl">
/// Full base URL ending in <c>/v1</c> — e.g. <c>http://127.0.0.1:38883/v1</c>.
/// Pass this to any OpenAI-compatible .NET HTTP client.
/// </param>
/// <param name="Port">The TCP port the server is listening on.</param>
/// <param name="Backend">Resolved backend (never <see cref="BackendKind.Auto"/>).</param>
/// <param name="ModelId">
/// Identifier surfaced via <c>/v1/models</c>. Defaults to the model filename
/// when <see cref="StartOptions.ModelId"/> was not supplied.
/// </param>
public sealed record BoundServer(
    string BaseUrl,
    int Port,
    BackendKind Backend,
    string ModelId);
