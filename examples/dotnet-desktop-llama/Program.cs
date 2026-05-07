using Avalonia;

namespace DvaiBridgeDesktopLlama;

internal static class Program
{
    /// <summary>
    /// Entry point. Spawns the Avalonia UI when stdout is a TTY / GUI
    /// session is available; falls back to a pure-console smoke run when
    /// the env var <c>DVAI_HEADLESS=1</c> is set (used by the smoke test
    /// script and CI).
    /// </summary>
    [STAThread]
    public static int Main(string[] args)
    {
        if (Environment.GetEnvironmentVariable("DVAI_HEADLESS") == "1"
            || (args.Length > 0 && args[0] == "--headless"))
        {
            // Headless smoke path: don't spin up the UI, just resolve the
            // facade + desktop slice and print a heartbeat. Used by the CI
            // smoke test script which doesn't have a display.
            return ConsoleSmoke.RunAsync(args).GetAwaiter().GetResult();
        }

        return BuildAvaloniaApp()
            .StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
