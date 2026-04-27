using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace DVAIBridge.Shared.Hosting;

/// <summary>
/// Embedded Kestrel host that exposes the OpenAI-compatible HTTP surface
/// (`/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`,
/// `/v1/models`). Adapts <see cref="IInferenceEngine.GenerateAsync"/>
/// streaming output to either SSE chunks (`stream: true`) or a single
/// batched JSON response.
/// </summary>
internal sealed class OpenAIServer : IAsyncDisposable
{
    private readonly IInferenceEngine _engine;
    private readonly IEmbeddingEngine? _embeddings;
    private readonly string _corsOrigin;
    private readonly string _backendWire;
    private WebApplication? _app;

    public string BaseUrl { get; private set; } = "";
    public int Port { get; private set; }
    public string ModelId => _engine.ModelId;

    public OpenAIServer(
        IInferenceEngine engine,
        BackendKind backend,
        string? corsOrigin = null,
        IEmbeddingEngine? embeddings = null)
    {
        _engine = engine;
        _embeddings = embeddings;
        _corsOrigin = corsOrigin ?? "*";
        _backendWire = backend.ToWireString();
    }

    public async Task StartAsync(int? basePort, int? maxAttempts, CancellationToken ct)
    {
        Port = PortPicker.FindFreePort(basePort, maxAttempts);
        BaseUrl = $"http://127.0.0.1:{Port}/v1";

        var builder = WebApplication.CreateBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseKestrel(opts =>
        {
            opts.ListenLocalhost(Port);
        });

        var app = builder.Build();

        app.Use(async (ctx, next) =>
        {
            ctx.Response.Headers["Access-Control-Allow-Origin"] = _corsOrigin;
            ctx.Response.Headers["Access-Control-Allow-Methods"] = "GET,POST,OPTIONS";
            ctx.Response.Headers["Access-Control-Allow-Headers"] = "*";
            if (HttpMethods.IsOptions(ctx.Request.Method))
            {
                ctx.Response.StatusCode = StatusCodes.Status204NoContent;
                return;
            }
            await next();
        });

        app.MapGet("/v1/models", () => Results.Json(new
        {
            @object = "list",
            data = new[]
            {
                new { id = _engine.ModelId, @object = "model", owned_by = "dvai-bridge", backend = _backendWire }
            }
        }));

        app.MapPost("/v1/chat/completions", HandleChatCompletions);
        app.MapPost("/v1/completions", HandleCompletions);
        app.MapPost("/v1/embeddings", HandleEmbeddings);

        await app.StartAsync(ct).ConfigureAwait(false);
        _app = app;
    }

    private async Task HandleChatCompletions(HttpContext ctx)
    {
        ChatCompletionRequest? req;
        try
        {
            req = await JsonSerializer.DeserializeAsync<ChatCompletionRequest>(
                ctx.Request.Body, JsonOpts, ctx.RequestAborted).ConfigureAwait(false);
        }
        catch (JsonException ex)
        {
            await WriteError(ctx, StatusCodes.Status400BadRequest, "invalid_request_error", ex.Message).ConfigureAwait(false);
            return;
        }
        if (req is null || req.Messages is null || req.Messages.Length == 0)
        {
            await WriteError(ctx, StatusCodes.Status400BadRequest, "invalid_request_error", "messages required").ConfigureAwait(false);
            return;
        }

        var prompt = AssembleChatPrompt(req.Messages);
        var opts = new GenerationOptions(
            MaxNewTokens: req.MaxTokens,
            Temperature: req.Temperature,
            TopP: req.TopP,
            TopK: req.TopK);

        if (req.Stream == true)
        {
            await StreamSseChatCompletion(ctx, prompt, opts).ConfigureAwait(false);
        }
        else
        {
            await BatchedChatCompletion(ctx, prompt, opts).ConfigureAwait(false);
        }
    }

    private async Task HandleCompletions(HttpContext ctx)
    {
        CompletionRequest? req;
        try
        {
            req = await JsonSerializer.DeserializeAsync<CompletionRequest>(
                ctx.Request.Body, JsonOpts, ctx.RequestAborted).ConfigureAwait(false);
        }
        catch (JsonException ex)
        {
            await WriteError(ctx, StatusCodes.Status400BadRequest, "invalid_request_error", ex.Message).ConfigureAwait(false);
            return;
        }
        if (req is null || string.IsNullOrEmpty(req.Prompt))
        {
            await WriteError(ctx, StatusCodes.Status400BadRequest, "invalid_request_error", "prompt required").ConfigureAwait(false);
            return;
        }

        var opts = new GenerationOptions(req.MaxTokens, req.Temperature, req.TopP, req.TopK);

        var sb = new StringBuilder();
        await foreach (var tok in _engine.GenerateAsync(req.Prompt, opts, ctx.RequestAborted))
        {
            sb.Append(tok);
        }

        var resp = new
        {
            id = "cmpl-" + Guid.NewGuid().ToString("N").Substring(0, 16),
            @object = "text_completion",
            created = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            model = _engine.ModelId,
            choices = new[]
            {
                new { text = sb.ToString(), index = 0, finish_reason = "stop" }
            }
        };
        await ctx.Response.WriteAsJsonAsync(resp, JsonOpts, ctx.RequestAborted).ConfigureAwait(false);
    }

    private async Task HandleEmbeddings(HttpContext ctx)
    {
        if (_embeddings is null)
        {
            ctx.Response.StatusCode = StatusCodes.Status501NotImplemented;
            await WriteError(ctx, StatusCodes.Status501NotImplemented, "unsupported",
                "Embeddings unsupported by the active backend (start with EmbeddingMode=true and an embedding model).").ConfigureAwait(false);
            return;
        }

        EmbeddingRequest? req;
        try
        {
            req = await JsonSerializer.DeserializeAsync<EmbeddingRequest>(
                ctx.Request.Body, JsonOpts, ctx.RequestAborted).ConfigureAwait(false);
        }
        catch (JsonException ex)
        {
            await WriteError(ctx, StatusCodes.Status400BadRequest, "invalid_request_error", ex.Message).ConfigureAwait(false);
            return;
        }
        if (req?.Input is null || req.Input.Length == 0)
        {
            await WriteError(ctx, StatusCodes.Status400BadRequest, "invalid_request_error", "input required").ConfigureAwait(false);
            return;
        }

        var vectors = await _embeddings.EmbedAsync(req.Input, ctx.RequestAborted).ConfigureAwait(false);
        var data = new List<object>(vectors.Length);
        for (var i = 0; i < vectors.Length; i++)
        {
            data.Add(new { @object = "embedding", embedding = vectors[i], index = i });
        }
        var resp = new
        {
            @object = "list",
            data,
            model = _engine.ModelId,
            usage = new { prompt_tokens = 0, total_tokens = 0 }
        };
        await ctx.Response.WriteAsJsonAsync(resp, JsonOpts, ctx.RequestAborted).ConfigureAwait(false);
    }

    private async Task StreamSseChatCompletion(HttpContext ctx, string prompt, GenerationOptions opts)
    {
        ctx.Response.Headers["Content-Type"] = "text/event-stream";
        ctx.Response.Headers["Cache-Control"] = "no-cache";
        ctx.Response.Headers["Connection"] = "keep-alive";

        var id = "chatcmpl-" + Guid.NewGuid().ToString("N").Substring(0, 16);
        var created = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        await foreach (var tok in _engine.GenerateAsync(prompt, opts, ctx.RequestAborted))
        {
            var chunk = new
            {
                id,
                @object = "chat.completion.chunk",
                created,
                model = _engine.ModelId,
                choices = new[]
                {
                    new { index = 0, delta = new { content = tok }, finish_reason = (string?)null }
                }
            };
            var json = JsonSerializer.Serialize(chunk, JsonOpts);
            await ctx.Response.WriteAsync($"data: {json}\n\n", ctx.RequestAborted).ConfigureAwait(false);
            await ctx.Response.Body.FlushAsync(ctx.RequestAborted).ConfigureAwait(false);
        }

        // Final stop chunk + [DONE].
        var final = new
        {
            id,
            @object = "chat.completion.chunk",
            created,
            model = _engine.ModelId,
            choices = new[]
            {
                new { index = 0, delta = new { }, finish_reason = "stop" }
            }
        };
        await ctx.Response.WriteAsync($"data: {JsonSerializer.Serialize(final, JsonOpts)}\n\n", ctx.RequestAborted).ConfigureAwait(false);
        await ctx.Response.WriteAsync("data: [DONE]\n\n", ctx.RequestAborted).ConfigureAwait(false);
        await ctx.Response.Body.FlushAsync(ctx.RequestAborted).ConfigureAwait(false);
    }

    private async Task BatchedChatCompletion(HttpContext ctx, string prompt, GenerationOptions opts)
    {
        var sb = new StringBuilder();
        await foreach (var tok in _engine.GenerateAsync(prompt, opts, ctx.RequestAborted))
        {
            sb.Append(tok);
        }

        var resp = new
        {
            id = "chatcmpl-" + Guid.NewGuid().ToString("N").Substring(0, 16),
            @object = "chat.completion",
            created = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            model = _engine.ModelId,
            choices = new[]
            {
                new
                {
                    index = 0,
                    message = new { role = "assistant", content = sb.ToString() },
                    finish_reason = "stop"
                }
            }
        };
        await ctx.Response.WriteAsJsonAsync(resp, JsonOpts, ctx.RequestAborted).ConfigureAwait(false);
    }

    private static string AssembleChatPrompt(ChatMessage[] messages)
    {
        // Default ChatML-like template — backends may override via their own
        // prompt formatting before calling Generate. This default works fine
        // for Llama-3 / Phi-3 / Qwen / Mistral instruct models.
        var sb = new StringBuilder();
        foreach (var m in messages)
        {
            var role = m.Role ?? "user";
            sb.Append("<|im_start|>").Append(role).Append('\n')
              .Append(m.Content ?? string.Empty)
              .Append("<|im_end|>\n");
        }
        sb.Append("<|im_start|>assistant\n");
        return sb.ToString();
    }

    private static async Task WriteError(HttpContext ctx, int statusCode, string type, string message)
    {
        ctx.Response.StatusCode = statusCode;
        await ctx.Response.WriteAsJsonAsync(new
        {
            error = new { type, message }
        }, JsonOpts).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (_app is not null)
        {
            await _app.StopAsync().ConfigureAwait(false);
            await _app.DisposeAsync().ConfigureAwait(false);
            _app = null;
        }
        await _engine.DisposeAsync().ConfigureAwait(false);
    }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    private sealed class ChatCompletionRequest
    {
        [JsonPropertyName("model")] public string? Model { get; set; }
        [JsonPropertyName("messages")] public ChatMessage[]? Messages { get; set; }
        [JsonPropertyName("temperature")] public double? Temperature { get; set; }
        [JsonPropertyName("top_p")] public double? TopP { get; set; }
        [JsonPropertyName("top_k")] public int? TopK { get; set; }
        [JsonPropertyName("max_tokens")] public int? MaxTokens { get; set; }
        [JsonPropertyName("stream")] public bool? Stream { get; set; }
    }

    private sealed class ChatMessage
    {
        [JsonPropertyName("role")] public string? Role { get; set; }
        [JsonPropertyName("content")] public string? Content { get; set; }
    }

    private sealed class CompletionRequest
    {
        [JsonPropertyName("model")] public string? Model { get; set; }
        [JsonPropertyName("prompt")] public string? Prompt { get; set; }
        [JsonPropertyName("temperature")] public double? Temperature { get; set; }
        [JsonPropertyName("top_p")] public double? TopP { get; set; }
        [JsonPropertyName("top_k")] public int? TopK { get; set; }
        [JsonPropertyName("max_tokens")] public int? MaxTokens { get; set; }
    }

    private sealed class EmbeddingRequest
    {
        [JsonPropertyName("model")] public string? Model { get; set; }
        [JsonPropertyName("input")] public string[]? Input { get; set; }
    }
}
