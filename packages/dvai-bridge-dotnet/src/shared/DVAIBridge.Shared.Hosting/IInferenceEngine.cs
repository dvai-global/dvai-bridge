using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace DVAIBridge.Shared.Hosting;

/// <summary>
/// One-method internal interface implemented by each backend
/// (LlamaInferenceEngine, OnnxGenAIRunner, MLNetInferenceEngine).
/// <see cref="OpenAIServer"/> calls <see cref="GenerateAsync"/> from the
/// HTTP request handler and adapts the streaming token output to either
/// SSE chunks (`stream: true`) or a single batched response.
/// </summary>
internal interface IInferenceEngine : IAsyncDisposable
{
    /// <summary>The bound model identifier surfaced via <c>GET /v1/models</c>.</summary>
    string ModelId { get; }

    /// <summary>Generate tokens for the given prompt.</summary>
    /// <param name="prompt">Already-templated prompt (the OpenAI server does the chat-template assembly).</param>
    /// <param name="opts">Sampling + stop options.</param>
    /// <param name="ct">Cancels the generation between iterations.</param>
    IAsyncEnumerable<string> GenerateAsync(string prompt, GenerationOptions opts, CancellationToken ct);
}

/// <summary>
/// Sampling parameters passed to <see cref="IInferenceEngine.GenerateAsync"/>.
/// All fields are optional; engines apply backend-appropriate defaults when
/// any field is null.
/// </summary>
internal sealed record GenerationOptions(
    int? MaxNewTokens,
    double? Temperature,
    double? TopP,
    int? TopK);

/// <summary>
/// Optional secondary capability — implemented by engines that support
/// embedding mode. <see cref="OpenAIServer"/> only exposes /v1/embeddings
/// when the bound engine implements this interface.
/// </summary>
internal interface IEmbeddingEngine
{
    /// <summary>Embed the given input strings into dense vectors.</summary>
    Task<float[][]> EmbedAsync(string[] inputs, CancellationToken ct);
}
