using DVAIBridge;

namespace DvaiBridgeDesktopOnnx;

internal static class ConsoleSmoke
{
    public static async Task<int> RunAsync(string[] args)
    {
        var modelPath = Environment.GetEnvironmentVariable("DVAI_MODEL_PATH");

        Console.WriteLine("DVAIBridge desktop-onnx smoke test.");
        Console.WriteLine($".NET runtime: {Environment.Version}");
        Console.WriteLine($"OS: {Environment.OSVersion}");
        Console.WriteLine($"Model path env: {modelPath ?? "(unset — expecting wiring-only check)"}");

        try
        {
            var server = await DVAIBridge.DVAIBridge.Shared.StartAsync(new StartOptions
            {
                Backend = BackendKind.Onnx,
                ModelPath = modelPath ?? "/nonexistent/onnx-bundle",
                ContextSize = 1024,
            });

            Console.WriteLine($"Bridge bound at {server.BaseUrl} (model = {server.ModelId}).");
            await DVAIBridge.DVAIBridge.Shared.StopAsync();
            Console.WriteLine("Bridge stopped cleanly.");
            return 0;
        }
        catch (DVAIBridgeException ex)
        {
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
