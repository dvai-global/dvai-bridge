using DVAIBridge;

namespace DvaiBridgeDesktopLlama;

/// <summary>
/// Pure-console runner used by the smoke test (no Avalonia, no display).
/// Exercises the same code path as the UI: facade.StartAsync → fail with
/// a clear DVAIBridgeException when the model file is missing (which IS
/// the assertion — we don't expect a real GGUF on CI / dev hosts).
///
/// Exit code:
///   0 — bridge resolved and produced an expected ConfigurationInvalid /
///       ModelLoadFailed exception (i.e. the slice is wired correctly).
///   1 — unexpected error (build / load failure of the slice itself).
/// </summary>
internal static class ConsoleSmoke
{
    public static async Task<int> RunAsync(string[] args)
    {
        var modelPath = Environment.GetEnvironmentVariable("DVAI_MODEL_PATH");

        Console.WriteLine("DVAIBridge desktop-llama smoke test.");
        Console.WriteLine($".NET runtime: {Environment.Version}");
        Console.WriteLine($"OS: {Environment.OSVersion}");
        Console.WriteLine($"Model path env: {modelPath ?? "(unset — expecting wiring-only check)"}");

        try
        {
            var server = await DVAIBridge.DVAIBridge.Shared.StartAsync(new StartOptions
            {
                Backend = BackendKind.Llama,
                ModelPath = modelPath ?? "/nonexistent/path.gguf",
                ContextSize = 1024,
                Threads = 2,
            });

            Console.WriteLine($"Bridge bound at {server.BaseUrl} (model = {server.ModelId}).");
            await DVAIBridge.DVAIBridge.Shared.StopAsync();
            Console.WriteLine("Bridge stopped cleanly.");
            return 0;
        }
        catch (DVAIBridgeException ex)
        {
            // Wiring is correct if we get back a typed DVAIBridge error
            // (the slice is loaded; only the model is missing). Any of
            // ConfigurationInvalid / ModelLoadFailed / BackendError /
            // BackendUnavailable counts as "wired".
            Console.WriteLine($"DVAIBridge error (expected when no model on disk): {ex.Kind} — {ex.Message}");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Unexpected non-DVAIBridge error: {ex}");
            return 1;
        }
    }
}
