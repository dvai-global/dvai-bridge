using Xunit;

namespace DVAIBridge.Tests;

public class BackendKindTests
{
    [Theory]
    [InlineData(BackendKind.Auto, "auto")]
    [InlineData(BackendKind.Llama, "llama")]
    [InlineData(BackendKind.Foundation, "foundation")]
    [InlineData(BackendKind.CoreML, "coreml")]
    [InlineData(BackendKind.MLX, "mlx")]
    [InlineData(BackendKind.MediaPipe, "mediapipe")]
    [InlineData(BackendKind.LiteRT, "litert")]
    [InlineData(BackendKind.Onnx, "onnx")]
    [InlineData(BackendKind.MLNet, "mlnet")]
    public void ToWireString_RoundTrips(BackendKind k, string expected)
    {
        Assert.Equal(expected, k.ToWireString());
    }

    [Theory]
    [InlineData("auto", BackendKind.Auto)]
    [InlineData("llama", BackendKind.Llama)]
    [InlineData("foundation", BackendKind.Foundation)]
    [InlineData("coreml", BackendKind.CoreML)]
    [InlineData("mlx", BackendKind.MLX)]
    [InlineData("mediapipe", BackendKind.MediaPipe)]
    [InlineData("litert", BackendKind.LiteRT)]
    [InlineData("onnx", BackendKind.Onnx)]
    [InlineData("mlnet", BackendKind.MLNet)]
    public void FromWireString_RoundTrips(string wire, BackendKind expected)
    {
        Assert.Equal(expected, BackendKindExtensions.FromWireString(wire));
    }

    [Fact]
    public void FromWireString_ThrowsOnUnknown()
    {
        var ex = Assert.Throws<System.ArgumentException>(() => BackendKindExtensions.FromWireString("nonexistent"));
        Assert.Contains("nonexistent", ex.Message);
    }

    [Fact]
    public void ToWireString_RejectsOutOfRange()
    {
        const BackendKind bogus = (BackendKind)999;
        Assert.Throws<System.ArgumentOutOfRangeException>(() => bogus.ToWireString());
    }
}
