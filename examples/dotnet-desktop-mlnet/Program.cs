using DVAIBridge;
using Microsoft.SemanticKernel;
using Microsoft.SemanticKernel.ChatCompletion;
using Microsoft.SemanticKernel.Connectors.OpenAI;

namespace DvaiBridgeDesktopMlnet;

/// <summary>
/// Console runner: loads a small ONNX classifier through the
/// DVAIBridge.MLNet slice and demonstrates that the SAME OpenAI-compatible
/// HTTP API the rest of the family uses for generative LLMs is also
/// served by a non-generative classifier — the "completion" the server
/// returns is a single classification label rather than a streamed
/// token sequence.
///
/// Why this matters: consumers don't have to switch HTTP shape between
/// generative and discriminative use cases. One client library
/// (Microsoft.SemanticKernel here, but anything OpenAI-compatible) drives
/// both.
///
/// v3.2.1 — distributed-inference pattern. ML.NET classifiers are
/// generally cheap enough to run locally on any modern desktop, but
/// the same <c>CapabilityPrecheck.Assess()</c> + offload pattern is
/// available if the consumer wants to centralise classification on a
/// dedicated Hub. Reference: <c>examples/dotnet-desktop-llama</c>.
/// </summary>
internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        var modelPath = Environment.GetEnvironmentVariable("DVAI_MODEL_PATH")
                        ?? (args.Length > 0 ? args[0] : null);
        var prompt = Environment.GetEnvironmentVariable("DVAI_PROMPT")
                     ?? (args.Length > 1 ? args[1] : "Classify this sentence.");
        var headless = Environment.GetEnvironmentVariable("DVAI_HEADLESS") == "1";

        Console.WriteLine("DVAIBridge desktop-mlnet sample (classifier on top of OpenAI API).");
        Console.WriteLine($".NET runtime: {Environment.Version}");
        Console.WriteLine($"OS: {Environment.OSVersion}");
        Console.WriteLine($"Model path: {modelPath ?? "(unset — wiring-only smoke)"}");

        BoundServer? server = null;

        try
        {
            server = await DVAIBridge.DVAIBridge.Shared.StartAsync(new StartOptions
            {
                Backend = BackendKind.MLNet,
                ModelPath = modelPath ?? "/nonexistent/classifier.onnx",
            });

            Console.WriteLine($"Bridge bound at {server.BaseUrl} (model = {server.ModelId}).");

            // Issue a single non-streaming chat completion. With a classifier
            // engine the response is the predicted label rather than a
            // generated token sequence.
            var kernel = Kernel.CreateBuilder()
                .AddOpenAIChatCompletion(
                    modelId: server.ModelId,
                    apiKey: "local-stub",
                    httpClient: new HttpClient
                    {
                        BaseAddress = new Uri(server.BaseUrl),
                    })
                .Build();

            var chat = kernel.GetRequiredService<IChatCompletionService>();
            var history = new ChatHistory();
            history.AddUserMessage(prompt);

            Console.WriteLine($"Prompt: {prompt}");
            Console.Write("Label : ");

            await foreach (var chunk in chat.GetStreamingChatMessageContentsAsync(history))
            {
                if (chunk.Content is { } token)
                {
                    Console.Write(token);
                }
            }
            Console.WriteLine();

            await DVAIBridge.DVAIBridge.Shared.StopAsync();
            return 0;
        }
        catch (DVAIBridgeException ex)
        {
            // In the wiring-only smoke (no real ONNX classifier on disk),
            // any DVAIBridge-typed error means the slice resolved correctly.
            Console.WriteLine($"DVAIBridge error (expected when no classifier on disk): {ex.Kind} — {ex.Message}");
            return headless ? 0 : 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Unexpected non-DVAIBridge error: {ex}");
            return 1;
        }
        finally
        {
            if (server is not null)
            {
                try { await DVAIBridge.DVAIBridge.Shared.StopAsync(); } catch { /* ignore */ }
            }
        }
    }
}
