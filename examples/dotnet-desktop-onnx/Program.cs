using Avalonia;

namespace DvaiBridgeDesktopOnnx;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (Environment.GetEnvironmentVariable("DVAI_HEADLESS") == "1"
            || (args.Length > 0 && args[0] == "--headless"))
        {
            return ConsoleSmoke.RunAsync(args).GetAwaiter().GetResult();
        }

        return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
