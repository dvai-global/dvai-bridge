using Avalonia.Controls;
using DVAIBridge;
using Microsoft.SemanticKernel;
using Microsoft.SemanticKernel.ChatCompletion;
using Microsoft.SemanticKernel.Connectors.OpenAI;

namespace DvaiBridgeDesktopOnnx;

public partial class MainWindow : Window
{
    private BoundServer? _server;

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

            var modelPath = string.IsNullOrWhiteSpace(ModelPathBox.Text)
                ? null
                : ModelPathBox.Text.Trim();

            if (modelPath is null)
            {
                StatusBlock.Text = "Model directory required for the ONNX backend.";
                StartBtn.IsEnabled = true;
                return;
            }

            _server = await DVAIBridge.DVAIBridge.Shared.StartAsync(new StartOptions
            {
                Backend = BackendKind.Onnx,
                ModelPath = modelPath,
                ContextSize = 4096,
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
