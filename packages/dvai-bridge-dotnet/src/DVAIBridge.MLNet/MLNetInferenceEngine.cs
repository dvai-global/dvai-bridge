using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.Shared.Hosting;
using Microsoft.ML;
using Microsoft.ML.Data;
using Microsoft.ML.Tokenizers;
using Microsoft.ML.Transforms.Onnx;

namespace DVAIBridge.MLNet;

/// <summary>
/// Implements <see cref="IInferenceEngine"/> over an ML.NET pipeline that
/// wraps an ONNX LLM via <see cref="OnnxScoringEstimator"/>. Runs the
/// pipeline once per token (no built-in KV cache — ML.NET's pipeline
/// abstraction predates streaming-LLM-style generators), and applies a
/// hand-rolled top-k / top-p / temperature sampler over the resulting
/// logits.
///
/// <para>Slower than direct ONNX Runtime + GenAI; suited to apps already
/// using ML.NET for non-LLM tasks. Greenfield consumers should prefer
/// <c>BackendKind.Onnx</c>.</para>
/// </summary>
internal sealed class MLNetInferenceEngine : IInferenceEngine
{
    private readonly MLContext _mlContext;
    private readonly ITransformer _transformer;
    private readonly Tokenizer _tokenizer;
    private readonly Random _rng = new();
    private bool _disposed;

    public string ModelId { get; }

    private MLNetInferenceEngine(MLContext mlContext, ITransformer transformer, Tokenizer tokenizer, string modelId)
    {
        _mlContext = mlContext;
        _transformer = transformer;
        _tokenizer = tokenizer;
        ModelId = modelId;
    }

    public static async Task<MLNetInferenceEngine> CreateAsync(string modelPath, string? tokenizerPath, string modelId, CancellationToken ct)
    {
        if (!File.Exists(modelPath))
        {
            throw DVAIBridgeException.ConfigurationInvalid($"ONNX model file not found: {modelPath}");
        }

        return await Task.Run(() =>
        {
            var mlContext = new MLContext(seed: 0);

            // Build a one-input/one-output ONNX pipeline. This is the canonical
            // ML.NET ONNX-transformer shape for LLM-style models exported with a
            // single `input_ids` -> `logits` mapping.
            var pipeline = mlContext.Transforms.ApplyOnnxModel(
                modelFile: modelPath,
                outputColumnNames: new[] { "logits" },
                inputColumnNames: new[] { "input_ids" });

            // Fit on an empty IDataView to materialize the transformer.
            var emptyView = mlContext.Data.LoadFromEnumerable(new List<TokenInput>());
            var transformer = pipeline.Fit(emptyView);

            // Tokenizer: prefer caller-supplied tokenizer.json, otherwise look
            // alongside the model. Microsoft.ML.Tokenizers has BPE support for
            // HF tokenizer.json since 1.0.0.
            var tokDir = Path.GetDirectoryName(modelPath) ?? ".";
            var tokenizerJson = tokenizerPath ?? Path.Combine(tokDir, "tokenizer.json");
            if (!File.Exists(tokenizerJson))
            {
                throw DVAIBridgeException.ConfigurationInvalid(
                    $"tokenizer.json not found at {tokenizerJson}. " +
                    "Pass StartOptions.TokenizerPath or place tokenizer.json next to the .onnx model.");
            }

            using var tokStream = File.OpenRead(tokenizerJson);
            var tokenizer = TiktokenTokenizer.Create(tokStream, preTokenizer: null, normalizer: null);
            return new MLNetInferenceEngine(mlContext, transformer, tokenizer, modelId);
        }, ct).ConfigureAwait(false);
    }

    public async IAsyncEnumerable<string> GenerateAsync(
        string prompt,
        GenerationOptions opts,
        [EnumeratorCancellation] CancellationToken ct)
    {
        if (_disposed) throw new ObjectDisposedException(nameof(MLNetInferenceEngine));

        await Task.Yield();

        var maxTokens = opts.MaxNewTokens ?? 256;
        var temperature = opts.Temperature ?? 0.7;
        var topP = opts.TopP ?? 0.9;
        var topK = opts.TopK ?? 40;

        var promptTokens = _tokenizer.EncodeToIds(prompt).ToList();
        var current = new List<long>(promptTokens.Select(i => (long)i));

        for (var step = 0; step < maxTokens; step++)
        {
            ct.ThrowIfCancellationRequested();

            var input = new TokenInput { input_ids = current.ToArray() };
            var view = _mlContext.Data.LoadFromEnumerable(new[] { input });
            var transformed = _transformer.Transform(view);

            var logits = _mlContext.Data.CreateEnumerable<TokenOutput>(transformed, reuseRowObject: false)
                .First().logits;

            // Take the last vocab-sized slice (final timestep's logits).
            // Models export logits as [seq_len, vocab_size] flattened — we
            // assume the standard layout where the last vocab_size values
            // correspond to the next-token distribution.
            var vocabSize = (int)(logits.Length / current.Count);
            if (vocabSize <= 0) yield break;
            var lastLogits = new float[vocabSize];
            Array.Copy(logits, logits.Length - vocabSize, lastLogits, 0, vocabSize);

            var nextToken = SampleToken(lastLogits, temperature, topP, topK);
            current.Add(nextToken);

            var piece = _tokenizer.Decode(new[] { (int)nextToken });
            if (!string.IsNullOrEmpty(piece))
            {
                yield return piece;
            }
        }
    }

    private int SampleToken(float[] logits, double temperature, double topP, int topK)
    {
        // 1. Temperature scaling.
        if (temperature > 0)
        {
            for (var i = 0; i < logits.Length; i++) logits[i] = (float)(logits[i] / temperature);
        }

        // 2. Top-k filter.
        if (topK > 0 && topK < logits.Length)
        {
            var threshold = logits.OrderByDescending(x => x).Skip(topK - 1).First();
            for (var i = 0; i < logits.Length; i++)
            {
                if (logits[i] < threshold) logits[i] = float.NegativeInfinity;
            }
        }

        // 3. Softmax.
        var maxLogit = logits.Max();
        var probs = new double[logits.Length];
        var sum = 0.0;
        for (var i = 0; i < logits.Length; i++)
        {
            probs[i] = Math.Exp(logits[i] - maxLogit);
            sum += probs[i];
        }
        for (var i = 0; i < probs.Length; i++) probs[i] /= sum;

        // 4. Top-p (nucleus) filter.
        if (topP < 1.0)
        {
            var sorted = probs.Select((p, i) => (p, i)).OrderByDescending(t => t.p).ToArray();
            var cumulative = 0.0;
            var keep = new HashSet<int>();
            foreach (var (p, i) in sorted)
            {
                keep.Add(i);
                cumulative += p;
                if (cumulative >= topP) break;
            }
            for (var i = 0; i < probs.Length; i++)
            {
                if (!keep.Contains(i)) probs[i] = 0;
            }
            var renorm = probs.Sum();
            if (renorm > 0) for (var i = 0; i < probs.Length; i++) probs[i] /= renorm;
        }

        // 5. Sample.
        var r = _rng.NextDouble();
        var c = 0.0;
        for (var i = 0; i < probs.Length; i++)
        {
            c += probs[i];
            if (r <= c) return i;
        }
        return probs.Length - 1;
    }

    public ValueTask DisposeAsync()
    {
        if (_disposed) return ValueTask.CompletedTask;
        _disposed = true;
        if (_transformer is IDisposable d) d.Dispose();
        return ValueTask.CompletedTask;
    }

    private sealed class TokenInput
    {
        [VectorType(0)]
        public long[] input_ids { get; set; } = Array.Empty<long>();
    }

    private sealed class TokenOutput
    {
        [VectorType(0)]
        public float[] logits { get; set; } = Array.Empty<float>();
    }
}
