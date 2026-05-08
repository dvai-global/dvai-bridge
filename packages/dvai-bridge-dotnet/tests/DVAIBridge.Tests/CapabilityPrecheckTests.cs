using System.Text.Json;
using DVAIBridge.Capability;
using Xunit;

namespace DVAIBridge.Tests;

/// <summary>
/// v3.2 — pre-init capability gate (.NET parallel to Android's
/// CapabilityPrecheckTest.kt + iOS CapabilityPrecheckTests.swift +
/// TS precheck.test.ts). Same hint shapes, same expected modes —
/// guarantees that .NET, iOS, Android, and the TS core agree on
/// what's a "too-weak" or "offload-only" device for any given
/// hardware profile.
/// </summary>
public class CapabilityPrecheckTests
{
    private static readonly DeviceCapabilityHints HighEndDesktop =
        new(HasNpu: false, RamGb: 32, GpuClass: GpuClass.Discrete, CpuClass: CpuClass.High);

    private static readonly DeviceCapabilityHints AppleSiliconLaptop =
        new(HasNpu: true, RamGb: 16, GpuClass: GpuClass.AppleSilicon, CpuClass: CpuClass.High);

    private static readonly DeviceCapabilityHints MidRangeLaptop =
        new(HasNpu: false, RamGb: 8, GpuClass: GpuClass.Integrated, CpuClass: CpuClass.Mid);

    private static readonly DeviceCapabilityHints LowEndLaptop =
        new(HasNpu: false, RamGb: 4, GpuClass: GpuClass.Integrated, CpuClass: CpuClass.Low);

    private static readonly DeviceCapabilityHints VeryWeakDevice =
        new(HasNpu: false, RamGb: 2, GpuClass: GpuClass.None, CpuClass: CpuClass.Low);

    [Fact]
    public void HighEndDesktop_ClassifiesAs_Ok()
    {
        var result = CapabilityPrecheck.Assess(hints: HighEndDesktop);
        Assert.Equal(PrecheckMode.Ok, result.Mode);
        Assert.True(result.TokPerSec > 10.0);
    }

    [Fact]
    public void AppleSilicon_ClassifiesAs_Ok()
    {
        var result = CapabilityPrecheck.Assess(hints: AppleSiliconLaptop);
        Assert.Equal(PrecheckMode.Ok, result.Mode);
    }

    [Fact]
    public void MidRangeLaptop_ClassifiesAs_OffloadOnly()
    {
        // 8 (integrated) * 1.0 (mid CPU) * 1.0 (8 GB RAM) * 1.0 (no NPU) = 8 tok/s
        // Above hardwareMinimum (3), below minLocalCapability (10) => offload-only.
        var result = CapabilityPrecheck.Assess(hints: MidRangeLaptop);
        Assert.Equal(PrecheckMode.OffloadOnly, result.Mode);
        Assert.Equal(8.0, result.TokPerSec, precision: 2);
    }

    [Fact]
    public void LowEndLaptop_ClassifiesAs_OffloadOnly()
    {
        // 8 * 0.6 * 0.7 = 3.4 tok/s => above floor (3), below comfort (10).
        var result = CapabilityPrecheck.Assess(hints: LowEndLaptop);
        Assert.Equal(PrecheckMode.OffloadOnly, result.Mode);
    }

    [Fact]
    public void VeryWeakDevice_ClassifiesAs_TooWeak()
    {
        // 3 (no GPU) * 0.6 (low CPU) * 0.3 (RAM < 4) = 0.5 tok/s => too-weak.
        var result = CapabilityPrecheck.Assess(hints: VeryWeakDevice);
        Assert.Equal(PrecheckMode.TooWeak, result.Mode);
        Assert.True(result.TokPerSec < 3.0);
    }

    [Fact]
    public void CustomHardwareMinimum_IsHonored()
    {
        // Mid-range gets 8 tok/s. Raise the floor above that => too-weak.
        var result = CapabilityPrecheck.Assess(
            hardwareMinimum: 12.0,
            hints: MidRangeLaptop);
        Assert.Equal(PrecheckMode.TooWeak, result.Mode);
    }

    [Fact]
    public void CustomMinLocalCapability_IsHonored()
    {
        // Mid-range gets 8 tok/s. Lower the comfort threshold to 5 => ok.
        var result = CapabilityPrecheck.Assess(
            minLocalCapability: 5.0,
            hints: MidRangeLaptop);
        Assert.Equal(PrecheckMode.Ok, result.Mode);
    }

    [Fact]
    public void Reason_Contains_TokPerSec()
    {
        var result = CapabilityPrecheck.Assess(hints: VeryWeakDevice);
        Assert.Contains("tok/s", result.Reason);
    }

    [Fact]
    public void HardwareAssessment_RoundTrips_AsJson()
    {
        var result = CapabilityPrecheck.Assess(hints: VeryWeakDevice);
        var json = JsonSerializer.Serialize(result);
        var decoded = JsonSerializer.Deserialize<HardwareAssessment>(json);
        Assert.NotNull(decoded);
        Assert.Equal(PrecheckMode.TooWeak, decoded!.Mode);
        Assert.True(decoded.TokPerSec < 3.0);
        Assert.Equal(VeryWeakDevice, decoded.Hints);
    }

    [Fact]
    public void WireFormat_MatchesCrossPlatform_KebabCase()
    {
        // Cross-platform parity: every other SDK reads / writes these
        // exact wire strings ("offload-only", "apple-silicon", etc.).
        var result = CapabilityPrecheck.Assess(hints: MidRangeLaptop);
        var json = JsonSerializer.Serialize(result);
        Assert.Contains("\"offload-only\"", json);
        Assert.Contains("\"integrated\"", json);
        Assert.Contains("\"mid\"", json);
    }
}
