using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.Shared.Hosting;

namespace DVAIBridge.Desktop;

/// <summary>
/// Implements <see cref="IInferenceEngine"/> over llama.cpp's C API
/// (<see cref="LlamaNative"/>). Single-threaded streaming generation:
/// tokenize → prefill via <c>llama_decode</c> → sample → append → decode →
/// yield piece, until EOS or <c>MaxNewTokens</c>.
/// </summary>
internal sealed class LlamaInferenceEngine : IInferenceEngine
{
    private readonly IntPtr _model;
    private readonly IntPtr _ctx;
    private readonly int _eosToken;
    private bool _disposed;

    public string ModelId { get; }

    public LlamaInferenceEngine(IntPtr model, IntPtr ctx, int eosToken, string modelId)
    {
        _model = model;
        _ctx = ctx;
        _eosToken = eosToken;
        ModelId = modelId;
    }

    public static async Task<LlamaInferenceEngine> CreateAsync(
        string modelPath,
        StartOptions opts,
        Action<ProgressEvent>? progress,
        CancellationToken ct)
    {
        if (!File.Exists(modelPath))
        {
            throw DVAIBridgeException.ModelLoadFailed($"Model file not found: {modelPath}");
        }

        progress?.Invoke(new ProgressEvent(ProgressKind.Started, ProgressPhase.Load, 0.0, "loading model"));

        // The actual native load is synchronous + slow; offload to thread pool.
        return await Task.Run(() =>
        {
            ct.ThrowIfCancellationRequested();
            LlamaNative.llama_backend_init();

            var modelParams = LlamaNative.llama_model_default_params();
            modelParams.n_gpu_layers = opts.GpuLayers ?? 0;

            var model = LlamaNative.llama_model_load_from_file(modelPath, modelParams);
            if (model == IntPtr.Zero)
            {
                throw DVAIBridgeException.ModelLoadFailed($"llama_model_load_from_file returned null for {modelPath}");
            }

            try
            {
                var ctxParams = LlamaNative.llama_context_default_params();
                ctxParams.n_ctx = (uint)(opts.ContextSize ?? 2048);
                ctxParams.n_threads = opts.Threads ?? Math.Min(8, Environment.ProcessorCount);
                ctxParams.n_threads_batch = ctxParams.n_threads;

                var llamaCtx = LlamaNative.llama_init_from_model(model, ctxParams);
                if (llamaCtx == IntPtr.Zero)
                {
                    throw DVAIBridgeException.ModelLoadFailed("llama_init_from_model returned null");
                }

                var eos = LlamaNative.llama_token_eos(model);
                progress?.Invoke(new ProgressEvent(ProgressKind.Completed, ProgressPhase.Ready, 100.0));

                var modelId = opts.ModelId ?? Path.GetFileNameWithoutExtension(modelPath);
                return new LlamaInferenceEngine(model, llamaCtx, eos, modelId);
            }
            catch
            {
                LlamaNative.llama_model_free(model);
                throw;
            }
        }, ct).ConfigureAwait(false);
    }

    public async IAsyncEnumerable<string> GenerateAsync(
        string prompt,
        GenerationOptions opts,
        [EnumeratorCancellation] CancellationToken ct)
    {
        if (_disposed) throw new ObjectDisposedException(nameof(LlamaInferenceEngine));

        var maxTokens = opts.MaxNewTokens ?? 256;
        var temperature = (float)(opts.Temperature ?? 0.7);
        var topP = (float)(opts.TopP ?? 0.9);
        var topK = opts.TopK ?? 40;

        // Build a sampler chain. The chain owns its constituent samplers
        // (chain_free walks the list); we don't free the individual nodes.
        var chainParams = LlamaNative.llama_sampler_chain_default_params();
        var chain = LlamaNative.llama_sampler_chain_init(chainParams);
        try
        {
            LlamaNative.llama_sampler_chain_add(chain, LlamaNative.llama_sampler_init_top_k(topK));
            LlamaNative.llama_sampler_chain_add(chain, LlamaNative.llama_sampler_init_top_p(topP, (UIntPtr)1));
            LlamaNative.llama_sampler_chain_add(chain, LlamaNative.llama_sampler_init_temp(temperature));
            LlamaNative.llama_sampler_chain_add(chain, LlamaNative.llama_sampler_init_dist((uint)Random.Shared.Next()));

            // Tokenize the prompt. First call sizes; second writes.
            var promptLen = Encoding.UTF8.GetByteCount(prompt);
            var tokensCap = Math.Max(8, promptLen + 16);
            var tokens = new int[tokensCap];
            var nTokens = LlamaNative.llama_tokenize(_model, prompt, promptLen, tokens, tokensCap, addSpecial: true, parseSpecial: true);
            if (nTokens < 0)
            {
                tokens = new int[-nTokens];
                nTokens = LlamaNative.llama_tokenize(_model, prompt, promptLen, tokens, tokens.Length, addSpecial: true, parseSpecial: true);
            }
            if (nTokens <= 0)
            {
                throw DVAIBridgeException.BackendError("Failed to tokenize prompt.");
            }

            // Prefill — one decode of the entire prompt.
            var promptPtr = Marshal.AllocHGlobal(sizeof(int) * nTokens);
            try
            {
                Marshal.Copy(tokens, 0, promptPtr, nTokens);
                var batch = LlamaNative.llama_batch_get_one(promptPtr, nTokens);
                var rc = LlamaNative.llama_decode(_ctx, batch);
                if (rc < 0)
                {
                    throw DVAIBridgeException.BackendError($"llama_decode (prefill) returned {rc}");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(promptPtr);
            }

            // Generate.
            var pieceBuf = new byte[64];
            for (var i = 0; i < maxTokens; i++)
            {
                ct.ThrowIfCancellationRequested();

                var token = LlamaNative.llama_sampler_sample(chain, _ctx, idx: -1);
                if (token == _eosToken) yield break;
                LlamaNative.llama_sampler_accept(chain, token);

                // Decode piece bytes for the sampled token.
                var pieceLen = LlamaNative.llama_token_to_piece(_model, token, pieceBuf, pieceBuf.Length, lstrip: 0, special: false);
                if (pieceLen < 0)
                {
                    pieceBuf = new byte[-pieceLen];
                    pieceLen = LlamaNative.llama_token_to_piece(_model, token, pieceBuf, pieceBuf.Length, lstrip: 0, special: false);
                }
                if (pieceLen > 0)
                {
                    yield return Encoding.UTF8.GetString(pieceBuf, 0, pieceLen);
                }

                // Decode the new token to extend the KV cache.
                var nextPtr = Marshal.AllocHGlobal(sizeof(int));
                try
                {
                    Marshal.Copy(new[] { token }, 0, nextPtr, 1);
                    var batch = LlamaNative.llama_batch_get_one(nextPtr, 1);
                    var rc = LlamaNative.llama_decode(_ctx, batch);
                    if (rc < 0) yield break;
                }
                finally
                {
                    Marshal.FreeHGlobal(nextPtr);
                }
            }
            await Task.CompletedTask;
        }
        finally
        {
            LlamaNative.llama_sampler_free(chain);
        }
    }

    public ValueTask DisposeAsync()
    {
        if (_disposed) return ValueTask.CompletedTask;
        _disposed = true;
        if (_ctx != IntPtr.Zero) LlamaNative.llama_free(_ctx);
        if (_model != IntPtr.Zero) LlamaNative.llama_model_free(_model);
        return ValueTask.CompletedTask;
    }
}
