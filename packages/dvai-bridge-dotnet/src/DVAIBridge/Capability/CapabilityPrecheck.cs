using System;
using System.Runtime.InteropServices;
using System.Text.Json.Serialization;

namespace DVAIBridge.Capability;

/// <summary>
/// v3.2 — pre-init capability gate.
///
/// Mirrors the Android <c>CapabilityPrecheck</c> + iOS
/// <c>CapabilityPrecheck</c> + TS <c>assessCapability()</c>
/// one-to-one. Same heuristic formula
/// (<c>gpuBase × cpuMul × ramMul × npuBonus</c>), same default
/// thresholds (3 tok/s hardware floor, 10 tok/s comfort threshold),
/// same three modes. Guarantees a given device classifies the same way
/// regardless of which SDK is asking.
///
/// <para>
/// Heuristic-only: no model is loaded, no probe runs at this stage.
/// The <see cref="CapabilityScore"/> probe path (post-load) refines
/// the estimate after a real request completes.
/// </para>
/// </summary>
public static class CapabilityPrecheck
{
    /// <summary>
    /// Default hardware floor in tok/s. Below this, the device is
    /// classified as <see cref="PrecheckMode.TooWeak"/>.
    /// </summary>
    public const double DefaultHardwareMinimum = 3.0;

    /// <summary>
    /// Default comfort threshold in tok/s. Below this, the device is
    /// classified as <see cref="PrecheckMode.OffloadOnly"/>.
    /// </summary>
    public const double DefaultMinLocalCapability = 10.0;

    /// <summary>
    /// Run the precheck. Pass <paramref name="hints"/> to override the
    /// auto-detect (used by tests + cross-platform parity checks).
    /// </summary>
    public static HardwareAssessment Assess(
        double hardwareMinimum = DefaultHardwareMinimum,
        double minLocalCapability = DefaultMinLocalCapability,
        DeviceCapabilityHints? hints = null)
    {
        var resolved = hints ?? DetectDeviceHints();
        var tokPerSec = HeuristicTokPerSec(resolved);

        if (tokPerSec < hardwareMinimum)
        {
            return new HardwareAssessment(
                Mode: PrecheckMode.TooWeak,
                TokPerSec: tokPerSec,
                Hints: resolved,
                Reason: $"estimated {tokPerSec} tok/s, below the " +
                        $"{hardwareMinimum} tok/s hardware floor — " +
                        "local inference would be unusable.");
        }

        if (tokPerSec < minLocalCapability)
        {
            return new HardwareAssessment(
                Mode: PrecheckMode.OffloadOnly,
                TokPerSec: tokPerSec,
                Hints: resolved,
                Reason: $"estimated {tokPerSec} tok/s, below the " +
                        $"{minLocalCapability} tok/s comfort threshold — " +
                        "model will not be loaded locally; every request will be " +
                        "forwarded to a paired peer.");
        }

        return new HardwareAssessment(
            Mode: PrecheckMode.Ok,
            TokPerSec: tokPerSec,
            Hints: resolved,
            Reason: $"estimated {tokPerSec} tok/s, above the " +
                    $"{minLocalCapability} tok/s threshold — running normally.");
    }

    /// <summary>
    /// Pure heuristic — mirrors the TS <c>heuristicTokPerSec</c> + the
    /// Kotlin/Swift versions. Pick the lowest factor across the four
    /// dimensions; the bottleneck is what actually limits inference.
    /// </summary>
    public static double HeuristicTokPerSec(DeviceCapabilityHints hints)
    {
        // Base score by GPU class — observed floors for 1–3B q4 GGUFs.
        var gpuBase = hints.GpuClass switch
        {
            GpuClass.None => 3.0,
            GpuClass.Integrated => 8.0,
            GpuClass.Discrete => 35.0,
            GpuClass.AppleSilicon => 40.0,
            _ => 3.0,
        };

        var cpuMul = hints.CpuClass switch
        {
            CpuClass.Low => 0.6,
            CpuClass.Mid => 1.0,
            CpuClass.High => 1.3,
            _ => 1.0,
        };

        var ramMul = hints.RamGb switch
        {
            < 4 => 0.3,
            < 8 => 0.7,
            _ => 1.0,
        };

        var npuBonus = hints.HasNpu ? 1.4 : 1.0;

        var raw = gpuBase * cpuMul * ramMul * npuBonus;
        return Math.Round(raw * 10) / 10;
    }

    /// <summary>
    /// Best-effort device introspection via <see cref="GC.GetGCMemoryInfo()"/>
    /// for RAM (HighMemoryLoadThresholdBytes is ~roughly system RAM) and
    /// <see cref="Environment.ProcessorCount"/> for CPU bucketing. GPU
    /// class defaults to <see cref="GpuClass.Integrated"/> on most
    /// platforms; <see cref="GpuClass.AppleSilicon"/> when running on
    /// arm64 macOS / Catalyst.
    /// </summary>
    public static DeviceCapabilityHints DetectDeviceHints()
    {
        // RAM via GC's MemoryInfo — TotalAvailableMemoryBytes is a
        // reasonable proxy for system RAM. On constrained hosts (mobile,
        // Linux containers with cgroup limits) this reports the cgroup
        // limit, which is the right number anyway.
        var memInfo = GC.GetGCMemoryInfo();
        var ramBytes = memInfo.TotalAvailableMemoryBytes;
        var ramGb = (int)(ramBytes / (1024L * 1024 * 1024));

        var cores = Environment.ProcessorCount;
        var cpuClass = cores switch
        {
            >= 8 => CpuClass.High,
            >= 4 => CpuClass.Mid,
            _ => CpuClass.Low,
        };

        // Apple Silicon detection: arm64 + macOS / Catalyst.
        var isArm64 = RuntimeInformation.OSArchitecture == Architecture.Arm64;
        var isAppleHost = OperatingSystem.IsMacOS() || OperatingSystem.IsMacCatalyst() ||
                          OperatingSystem.IsIOS();
        var gpuClass = (isArm64 && isAppleHost) ? GpuClass.AppleSilicon : GpuClass.Integrated;
        var hasNpu = isArm64 && isAppleHost;

        return new DeviceCapabilityHints(
            HasNpu: hasNpu,
            RamGb: Math.Max(0, ramGb),
            GpuClass: gpuClass,
            CpuClass: cpuClass);
    }
}

/// <summary>
/// JSON-serializable result of <see cref="CapabilityPrecheck.Assess"/>
/// (and the public <c>DVAIBridge.AssessHardware()</c> method).
///
/// <para>
/// The SDK never shows UI for hardware decisions — consumer apps query
/// this and decide their own UX based on <see cref="Mode"/>.
/// </para>
/// </summary>
/// <param name="Mode">Lifecycle mode the SDK would enter on <c>StartAsync</c>.</param>
/// <param name="TokPerSec">Estimated decode tok/s for any 1–3B-class model.</param>
/// <param name="Reason">Human-readable explanation; safe to log + display.</param>
/// <param name="Hints">Underlying hints used to compute the estimate.</param>
public sealed record HardwareAssessment(
    [property: JsonPropertyName("mode")] PrecheckMode Mode,
    [property: JsonPropertyName("tokPerSec")] double TokPerSec,
    [property: JsonPropertyName("reason")] string Reason,
    [property: JsonPropertyName("hints")] DeviceCapabilityHints Hints);

/// <summary>Coarse hardware hints used by the precheck heuristic.</summary>
public sealed record DeviceCapabilityHints(
    [property: JsonPropertyName("hasNpu")] bool HasNpu,
    [property: JsonPropertyName("ramGb")] int RamGb,
    [property: JsonPropertyName("gpuClass")] GpuClass GpuClass,
    [property: JsonPropertyName("cpuClass")] CpuClass CpuClass);

/// <summary>
/// Lifecycle mode the SDK enters on <c>StartAsync</c>. Serialized as
/// kebab-case strings (<c>"ok"</c> / <c>"offload-only"</c> /
/// <c>"too-weak"</c>) for cross-platform parity with the Kotlin / Swift
/// / TS values.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<PrecheckMode>))]
public enum PrecheckMode
{
    /// <summary>Device can comfortably run the model locally.</summary>
    [JsonStringEnumMemberName("ok")] Ok,
    /// <summary>Device can run but slowly; route requests to a paired peer.</summary>
    [JsonStringEnumMemberName("offload-only")] OffloadOnly,
    /// <summary>Device is below the hardware floor; consumer should typically bail.</summary>
    [JsonStringEnumMemberName("too-weak")] TooWeak,
}

/// <summary>GPU class buckets used by the heuristic.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<GpuClass>))]
public enum GpuClass
{
    /// <summary>No GPU acceleration — CPU-only inference.</summary>
    [JsonStringEnumMemberName("none")] None,
    /// <summary>Integrated GPU (mobile / iGPU).</summary>
    [JsonStringEnumMemberName("integrated")] Integrated,
    /// <summary>Dedicated discrete GPU (e.g. RTX-class).</summary>
    [JsonStringEnumMemberName("discrete")] Discrete,
    /// <summary>Apple Silicon unified memory + Metal.</summary>
    [JsonStringEnumMemberName("apple-silicon")] AppleSilicon,
}

/// <summary>CPU class buckets used by the heuristic.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CpuClass>))]
public enum CpuClass
{
    /// <summary>Low core count (&lt; 4 logical cores).</summary>
    [JsonStringEnumMemberName("low")] Low,
    /// <summary>Mid core count (4–7 logical cores).</summary>
    [JsonStringEnumMemberName("mid")] Mid,
    /// <summary>High core count (8+ logical cores).</summary>
    [JsonStringEnumMemberName("high")] High,
}
