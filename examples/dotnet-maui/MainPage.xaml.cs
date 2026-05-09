using DVAIBridge;
using Microsoft.SemanticKernel;
using Microsoft.SemanticKernel.ChatCompletion;
using Microsoft.SemanticKernel.Connectors.OpenAI;

namespace DvaiBridgeMauiSample;

/// <summary>
/// Single-page chat shell: pick a backend, start the bridge, type a
/// prompt, see the streaming response. The OpenAI-compatible client is
/// Microsoft.SemanticKernel pointed at the BoundServer.BaseUrl returned
/// by DVAIBridge.Shared.StartAsync(...).
///
/// v3.2.1 — distributed-inference pattern. .NET MAUI shares the
/// DVAIBridge core API with Desktop, so the same pre-init capability
/// gate via <c>CapabilityPrecheck.Assess()</c> and paired-Hub offload
/// via <c>OffloadConfig { Enabled = true, KnownPeers = [...] }</c>
/// are available. Reference: <c>examples/dotnet-desktop-llama</c> for
/// the full local-or-offload branch; <c>examples/ios-offload-dogfood</c>
/// for the cross-platform pairing flow.
/// </summary>
public partial class MainPage : ContentPage
{
    private BoundServer? _server;

    public MainPage()
    {
        InitializeComponent();
        PopulateBackendPicker();
    }

    private void PopulateBackendPicker()
    {
        // The set of backends valid on the current platform. The facade
        // pre-validates on StartAsync, but we hide the obviously-invalid
        // options to avoid noise in the picker.
        var backends = new List<string> { "Auto", "Llama" };
#if MACCATALYST
        backends.AddRange(new[] { "Foundation", "CoreML", "MLX", "Onnx" });
#elif IOS
        backends.AddRange(new[] { "Foundation", "CoreML", "MLX" });
#elif ANDROID
        backends.AddRange(new[] { "MediaPipe", "LiteRT" });
#endif

        BackendPicker.ItemsSource = backends;
        BackendPicker.SelectedIndex = 0;
    }

    private async void OnStartClicked(object? sender, EventArgs e)
    {
        try
        {
            StartBtn.IsEnabled = false;
            StatusLabel.Text = "Starting bridge…";

            var backendName = BackendPicker.SelectedItem as string ?? "Auto";
            var backend = Enum.Parse<BackendKind>(backendName);

            var modelPath = string.IsNullOrWhiteSpace(ModelPathEntry.Text)
                ? null
                : ModelPathEntry.Text.Trim();

            _server = await DVAIBridge.DVAIBridge.Shared.StartAsync(new StartOptions
            {
                Backend = backend,
                ModelPath = modelPath,
                ContextSize = 2048,
                Threads = 4,
            });

            StatusLabel.Text = $"Bound: {_server.BaseUrl} (backend = {_server.Backend}, model = {_server.ModelId}).";
            StopBtn.IsEnabled = true;
            SendBtn.IsEnabled = true;
        }
        catch (DVAIBridgeException ex)
        {
            StatusLabel.Text = $"DVAIBridge error: {ex.Kind} — {ex.Message}";
            StartBtn.IsEnabled = true;
        }
        catch (Exception ex)
        {
            StatusLabel.Text = $"Unexpected error: {ex.Message}";
            StartBtn.IsEnabled = true;
        }
    }

    private async void OnStopClicked(object? sender, EventArgs e)
    {
        try
        {
            StopBtn.IsEnabled = false;
            SendBtn.IsEnabled = false;
            await DVAIBridge.DVAIBridge.Shared.StopAsync();
            StatusLabel.Text = "Stopped.";
            _server = null;
            StartBtn.IsEnabled = true;
        }
        catch (Exception ex)
        {
            StatusLabel.Text = $"Stop failed: {ex.Message}";
        }
    }

    private async void OnSendClicked(object? sender, EventArgs e)
    {
        if (_server is null)
        {
            StatusLabel.Text = "Bridge not started — click Start first.";
            return;
        }

        try
        {
            SendBtn.IsEnabled = false;
            ResponseLabel.Text = string.Empty;

            // Build a Microsoft.SemanticKernel chat client pointed at the
            // bound local server. Any string works as the API key — the
            // local server doesn't authenticate.
            var kernel = Kernel.CreateBuilder()
                .AddOpenAIChatCompletion(
                    modelId: _server.ModelId,
                    apiKey: "local-stub",
                    httpClient: new HttpClient
                    {
                        BaseAddress = new Uri(_server.BaseUrl),
                    })
                .Build();

            var chat = kernel.GetRequiredService<IChatCompletionService>();
            var history = new ChatHistory();
            history.AddUserMessage(PromptEditor.Text);

            await foreach (var chunk in chat.GetStreamingChatMessageContentsAsync(history))
            {
                if (chunk.Content is { } token)
                {
                    ResponseLabel.Text += token;
                }
            }
        }
        catch (Exception ex)
        {
            StatusLabel.Text = $"Send failed: {ex.Message}";
        }
        finally
        {
            SendBtn.IsEnabled = true;
        }
    }
}
