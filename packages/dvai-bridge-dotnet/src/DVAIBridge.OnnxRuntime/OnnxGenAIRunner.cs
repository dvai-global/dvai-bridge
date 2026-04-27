using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.Shared.Hosting;
using Microsoft.ML.OnnxRuntimeGenAI;

namespace DVAIBridge.OnnxRuntime;

/// <summary>
/// Wraps <see cref="Microsoft.ML.OnnxRuntimeGenAI.Generator"/> against an
/// HF-style ONNX-GenAI model directory (<c>model.onnx</c> +
/// <c>genai_config.json</c> + <c>tokenizer.json</c>).
/// </summary>
internal sealed class OnnxGenAIRunner : IInferenceEngine
{
    private readonly Model _model;
    private readonly Tokenizer _tokenizer;
    private bool _disposed;

    public string ModelId { get; }

    public OnnxGenAIRunner(string modelDir, string modelId)
    {
        if (!Directory.Exists(modelDir))
        {
            throw DVAIBridgeException.ConfigurationInvalid($"ONNX model directory not found: {modelDir}");
        }

        // Validate the HF ONNX-GenAI layout — fail-fast with a clear error.
        var configPath = Path.Combine(modelDir, "genai_config.json");
        if (!File.Exists(configPath))
        {
            throw DVAIBridgeException.ConfigurationInvalid(
                $"genai_config.json missing in {modelDir} — expected HuggingFace ONNX-GenAI directory layout " +
                "(model.onnx + genai_config.json + tokenizer.json).");
        }

        _model = new Model(modelDir);
        _tokenizer = new Tokenizer(_model);
        ModelId = modelId;
    }

    public async IAsyncEnumerable<string> GenerateAsync(
        string prompt,
        GenerationOptions opts,
        [EnumeratorCancellation] CancellationToken ct)
    {
        if (_disposed) throw new ObjectDisposedException(nameof(OnnxGenAIRunner));

        await Task.Yield();

        using var sequences = _tokenizer.Encode(prompt);

        using var generatorParams = new GeneratorParams(_model);
        generatorParams.SetSearchOption("max_length", opts.MaxNewTokens ?? 256);
        if (opts.Temperature is { } t) generatorParams.SetSearchOption("temperature", t);
        if (opts.TopP is { } p) generatorParams.SetSearchOption("top_p", p);
        if (opts.TopK is { } k) generatorParams.SetSearchOption("top_k", k);

        using var generator = new Generator(_model, generatorParams);
        generator.AppendTokenSequences(sequences);

        using var streamer = _tokenizer.CreateStream();
        while (!generator.IsDone())
        {
            ct.ThrowIfCancellationRequested();
            generator.GenerateNextToken();
            var nextTokens = generator.GetNextTokens();
            if (nextTokens.Length == 0) continue;
            var piece = streamer.Decode(nextTokens[0]);
            if (!string.IsNullOrEmpty(piece))
            {
                yield return piece;
            }
        }
    }

    public ValueTask DisposeAsync()
    {
        if (_disposed) return ValueTask.CompletedTask;
        _disposed = true;
        _tokenizer.Dispose();
        _model.Dispose();
        return ValueTask.CompletedTask;
    }
}
