using Avalonia.Controls;
using DVAIBridge;
using DVAIBridge.Capability;
using Microsoft.SemanticKernel;
using Microsoft.SemanticKernel.ChatCompletion;
using Microsoft.SemanticKernel.Connectors.OpenAI;

namespace DvaiBridgeDesktopLlama;

public partial class MainWindow : Window
{
    private BoundServer? _server;

    // v3.2.1 — distributed-inference scaffold. If `AssessHardware`
    // reports the desktop can't run llama.cpp comfortably (rare on
    // a desktop, but possible on older laptops with no discrete GPU),
    // we route the chat through a paired DVAI Hub on the LAN. Set
    // `HubUrl` to enable the offload path. Leave it null to require
    // local-only inference.
    private const string? HubUrl = null;  // e.g. "http://192.168.1.42:38883"

    public MainWindow()
    {
        InitializeComponent();
    }

    private async void OnStart(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
    {
        try
        {
            StartBtn.IsEnabled = false;
            StatusBlock.Text = "Starting bridge…";

            // v3.2.1 — pre-init capability gate. Decide local-vs-offload
            // BEFORE we touch a potentially-large GGUF file.
            var assessment = CapabilityPrecheck.Assess();
            StatusBlock.Text = $"Hardware: {assessment.Mode} ({assessment.TokPerSec:F1} tok/s est)";

            if (assessment.Mode == PrecheckMode.TooWeak)
            {
                StatusBlock.Text = $"Device too weak for inference: {assessment.Reason}";
                StartBtn.IsEnabled = true;
                return;
            }

            if (assessment.Mode == PrecheckMode.OffloadOnly)
            {
                if (HubUrl is null)
                {
                    StatusBlock.Text =
                        "Device too slow for local llama.cpp. Set HubUrl to a paired DVAI Hub.";
                    StartBtn.IsEnabled = true;
                    return;
                }
                // The OffloadRouter is wired up internally by the
                // Desktop slice when OffloadConfig.Enabled is true;
                // chat completions arriving at the bound port are
                // forwarded transparently to the Hub.
                _server = await DVAIBridge.DVAIBridge.Shared.StartAsync(new StartOptions
                {
                    Backend = BackendKind.Llama,
                    ModelPath = "",  // offload-only — no local model load
                    Offload = new OffloadConfig
                    {
                        Enabled = true,
                        DiscoverLAN = true,
                        MinLocalCapability = 999.0,  // force offload-only
                        KnownPeers = new[]
                        {
                            new DVAIBridge.PeerInfo
                            {
                                DeviceId = $"manual:{HubUrl}",
                                DeviceName = "DVAI Hub",
                                DvaiVersion = "unknown",
                                BaseUrl = HubUrl!.EndsWith("/v1") ? HubUrl : HubUrl + "/v1",
                            },
                        },
                    },
                });

                StatusBlock.Text = $"Started in offload-only mode → {HubUrl}.";
                StopBtn.IsEnabled = true;
                SendBtn.IsEnabled = true;
                return;
            }

            // assessment.Mode == PrecheckMode.Ok — local inference path.
            var modelPath = string.IsNullOrWhiteSpace(ModelPathBox.Text)
                ? null
                : ModelPathBox.Text.Trim();

            if (modelPath is null)
            {
                StatusBlock.Text = "Model path required for the Llama backend.";
                StartBtn.IsEnabled = true;
                return;
            }

            _server = await DVAIBridge.DVAIBridge.Shared.StartAsync(new StartOptions
            {
                Backend = BackendKind.Llama,
                ModelPath = modelPath,
                ContextSize = 2048,
                Threads = Environment.ProcessorCount,
            });

            StatusBlock.Text = $"Bound: {_server.BaseUrl} (backend = {_server.Backend}, model = {_server.ModelId}).";
            StopBtn.IsEnabled = true;
            SendBtn.IsEnabled = true;
        }
        catch (DVAIBridgeException ex)
        {
            StatusBlock.Text = $"DVAIBridge error: {ex.Kind} — {ex.Message}";
            StartBtn.IsEnabled = true;
        }
        catch (Exception ex)
        {
            StatusBlock.Text = $"Unexpected error: {ex.Message}";
            StartBtn.IsEnabled = true;
        }
    }

    private async void OnStop(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
    {
        try
        {
            StopBtn.IsEnabled = false;
            SendBtn.IsEnabled = false;
            await DVAIBridge.DVAIBridge.Shared.StopAsync();
            _server = null;
            StatusBlock.Text = "Stopped.";
            StartBtn.IsEnabled = true;
        }
        catch (Exception ex)
        {
            StatusBlock.Text = $"Stop failed: {ex.Message}";
        }
    }

    private async void OnSend(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
    {
        if (_server is null)
        {
            StatusBlock.Text = "Bridge not started.";
            return;
        }

        try
        {
            SendBtn.IsEnabled = false;
            ResponseBlock.Text = string.Empty;

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
            history.AddUserMessage(PromptBox.Text ?? string.Empty);

            await foreach (var chunk in chat.GetStreamingChatMessageContentsAsync(history))
            {
                if (chunk.Content is { } token)
                {
                    ResponseBlock.Text += token;
                }
            }
        }
        catch (Exception ex)
        {
            StatusBlock.Text = $"Send failed: {ex.Message}";
        }
        finally
        {
            SendBtn.IsEnabled = true;
        }
    }
}
