using Xunit;

namespace DVAIBridge.Tests;

public class StartOptionsTests
{
    [Fact]
    public void Defaults_AreSensible()
    {
        var opts = new StartOptions { Backend = BackendKind.Llama };
        Assert.Equal(BackendKind.Llama, opts.Backend);
        Assert.Null(opts.ModelPath);
        Assert.Null(opts.ContextSize);
        Assert.False(opts.EmbeddingMode);
        Assert.False(opts.VisionEnabled);
    }

    [Fact]
    public void With_PreservesUntouchedFields()
    {
        var original = new StartOptions
        {
            Backend = BackendKind.Llama,
            ModelPath = "/tmp/a.gguf",
            ContextSize = 2048,
            Threads = 4,
        };

        var modified = original with { ContextSize = 4096 };

        Assert.Equal(4096, modified.ContextSize);
        Assert.Equal(BackendKind.Llama, modified.Backend);
        Assert.Equal("/tmp/a.gguf", modified.ModelPath);
        Assert.Equal(4, modified.Threads);
        // Original is untouched (records are immutable).
        Assert.Equal(2048, original.ContextSize);
    }

    [Fact]
    public void Equality_IsValueBased()
    {
        var a = new StartOptions { Backend = BackendKind.MediaPipe, ModelPath = "/m" };
        var b = new StartOptions { Backend = BackendKind.MediaPipe, ModelPath = "/m" };
        Assert.Equal(a, b);
        Assert.Equal(a.GetHashCode(), b.GetHashCode());
    }
}
