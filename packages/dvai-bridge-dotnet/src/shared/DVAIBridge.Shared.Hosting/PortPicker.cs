using System;
using System.Net;
using System.Net.Sockets;

namespace DVAIBridge.Shared.Hosting;

/// <summary>
/// Walks the requested port range looking for the first free 127.0.0.1
/// binding. Used by <see cref="OpenAIServer"/> to honor
/// <c>StartOptions.HttpBasePort</c> + <c>HttpMaxPortAttempts</c> the same
/// way the Phase 3A Swift / Kotlin servers do.
/// </summary>
internal static class PortPicker
{
    public const int DefaultBasePort = 38883;
    public const int DefaultMaxAttempts = 16;

    /// <summary>
    /// Returns the first available 127.0.0.1 port in the requested range.
    /// Throws <see cref="DVAIBridgeException"/> with kind
    /// <see cref="DVAIBridgeErrorKind.ConfigurationInvalid"/> when every port
    /// in the range is occupied.
    /// </summary>
    public static int FindFreePort(int? basePort, int? maxAttempts)
    {
        var start = basePort ?? DefaultBasePort;
        var attempts = maxAttempts ?? DefaultMaxAttempts;
        if (attempts < 1) attempts = 1;

        for (var i = 0; i < attempts; i++)
        {
            var candidate = start + i;
            if (candidate is < 1 or > 65535) continue;
            if (IsFree(candidate)) return candidate;
        }

        throw DVAIBridgeException.ConfigurationInvalid(
            $"No port available in range [{start}, {start + attempts - 1}].");
    }

    private static bool IsFree(int port)
    {
        try
        {
            using var listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            listener.Stop();
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
    }
}
