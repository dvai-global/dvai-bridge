using System.Text.Json.Serialization;

namespace DVAIBridge.Capability;

/// <summary>
/// An estimate of decode tok/s for a given (model, device) pair on this
/// device. Used by the offload decider to pick local vs. peer execution
/// per request. Mirrors the TypeScript <c>CapabilityScore</c> type in
/// <c>@dvai-bridge/core</c>.
/// </summary>
/// <param name="ModelId">Model identifier this score applies to.</param>
/// <param name="DeviceId">Stable per-install device identifier.</param>
/// <param name="LibraryVersion">Library SemVer at the time the score was measured.</param>
/// <param name="TokPerSec">Estimated decode rate, tokens-per-second.</param>
/// <param name="Source">Source of the estimate — <c>"probe"</c> or <c>"heuristic"</c>.</param>
/// <param name="MeasuredAt">Unix milliseconds the score was measured / computed.</param>
public sealed record CapabilityScore(
    [property: JsonPropertyName("modelId")] string ModelId,
    [property: JsonPropertyName("deviceId")] string DeviceId,
    [property: JsonPropertyName("libraryVersion")] string LibraryVersion,
    [property: JsonPropertyName("tokPerSec")] double TokPerSec,
    [property: JsonPropertyName("source")] string Source,
    [property: JsonPropertyName("measuredAt")] long MeasuredAt);
