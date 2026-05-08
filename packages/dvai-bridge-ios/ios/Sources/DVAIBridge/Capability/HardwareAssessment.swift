import Foundation

/// v3.2 — JSON-serializable result of `DVAIBridge.shared.assessHardware()`.
///
/// Returned to consumer code so the app developer can decide whether
/// to call `DVAIBridge.shared.start(...)` and what (if anything) to
/// surface in the UI. The SDK itself never shows UI for hardware
/// decisions — consumer apps make those choices.
///
/// `Codable` so it round-trips cleanly through Capacitor / React
/// Native / Pigeon bridges as JSON without any custom converter.
public struct HardwareAssessment: Sendable, Codable, Equatable {
    /// Lifecycle mode the SDK would enter on `start()`. See
    /// `PrecheckMode` for the three values.
    public let mode: PrecheckMode
    /// Estimated decode tok/s for any 1–3B-class model on this device.
    public let tokPerSec: Double
    /// Human-readable explanation; safe to log + display.
    public let reason: String
    /// Underlying hints used to compute the estimate.
    public let hints: DeviceCapabilityHints

    public init(
        mode: PrecheckMode,
        tokPerSec: Double,
        reason: String,
        hints: DeviceCapabilityHints
    ) {
        self.mode = mode
        self.tokPerSec = tokPerSec
        self.reason = reason
        self.hints = hints
    }

    init(from result: CapabilityPrecheck.Result) {
        self.mode = result.mode
        self.tokPerSec = result.tokPerSec
        self.reason = result.reason
        self.hints = result.hints
    }
}
