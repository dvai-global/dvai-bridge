import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// v3.2 — pre-init capability gate (Swift port of the Kotlin
/// `CapabilityPrecheck` and the TS `assessCapability`).
///
/// Mirrors the Android + TS heuristic 1:1 — same hint shapes, same
/// threshold defaults (3 tok/s hardware floor, 10 tok/s comfort
/// threshold), same three modes. Guarantees that a given device
/// classifies the same way regardless of which platform's SDK is
/// asking.
///
/// Heuristic-only: no model is loaded, no probe runs. The cold-run
/// probe (`probeCapability`) refines the estimate AFTER the model is
/// loaded and a request has actually completed; that path is unchanged
/// from v3.0.
public enum CapabilityPrecheck {

    /// Result of `assess(...)`. `Codable` so it can serialize cleanly
    /// to JSON for cross-language Pigeon / Capacitor bridges.
    public struct Result: Sendable, Codable, Equatable {
        public let mode: PrecheckMode
        /// Estimated decode tok/s for any 1–3B-class model.
        public let tokPerSec: Double
        public let hints: DeviceCapabilityHints
        /// Human-readable explanation; safe to log + display.
        public let reason: String
    }

    /// Tunable thresholds. Defaults match `OffloadConfig` / the Kotlin
    /// `CapabilityPrecheck.Thresholds` / the TS defaults.
    public struct Thresholds: Sendable {
        /// Below this, the device is too weak to run inference at all.
        /// Default 3.0 tok/s.
        public var hardwareMinimum: Double
        /// Below this, run in offload-only mode. Default 10.0.
        public var minLocalCapability: Double

        public init(hardwareMinimum: Double = 3.0, minLocalCapability: Double = 10.0) {
            self.hardwareMinimum = hardwareMinimum
            self.minLocalCapability = minLocalCapability
        }
    }

    /// Run the precheck. Pass `hints` to override the auto-detect (used
    /// by tests + cross-platform parity checks).
    public static func assess(
        thresholds: Thresholds = Thresholds(),
        hints: DeviceCapabilityHints? = nil
    ) -> Result {
        let resolvedHints = hints ?? detectDeviceHints()
        let tokPerSec = heuristicTokPerSec(hints: resolvedHints)

        if tokPerSec < thresholds.hardwareMinimum {
            return Result(
                mode: .tooWeak,
                tokPerSec: tokPerSec,
                hints: resolvedHints,
                reason: "estimated \(tokPerSec) tok/s, below the " +
                    "\(thresholds.hardwareMinimum) tok/s hardware floor — " +
                    "local inference would be unusable."
            )
        }

        if tokPerSec < thresholds.minLocalCapability {
            return Result(
                mode: .offloadOnly,
                tokPerSec: tokPerSec,
                hints: resolvedHints,
                reason: "estimated \(tokPerSec) tok/s, below the " +
                    "\(thresholds.minLocalCapability) tok/s comfort threshold — " +
                    "model will not be loaded locally; every request will be " +
                    "forwarded to a paired peer."
            )
        }

        return Result(
            mode: .ok,
            tokPerSec: tokPerSec,
            hints: resolvedHints,
            reason: "estimated \(tokPerSec) tok/s, above the " +
                "\(thresholds.minLocalCapability) tok/s threshold — running normally."
        )
    }

    /// Pure heuristic — mirrors the TS `heuristicTokPerSec` and
    /// Kotlin's `CapabilityPrecheck.heuristicTokPerSec`.
    public static func heuristicTokPerSec(hints: DeviceCapabilityHints) -> Double {
        // Base score by GPU class — observed floors for 1–3B q4 GGUFs.
        let gpuBase: Double
        switch hints.gpuClass {
        case .none: gpuBase = 3.0
        case .integrated: gpuBase = 8.0
        case .discrete: gpuBase = 35.0
        case .appleSilicon: gpuBase = 40.0
        }

        let cpuMul: Double
        switch hints.cpuClass {
        case .low: cpuMul = 0.6
        case .mid: cpuMul = 1.0
        case .high: cpuMul = 1.3
        }

        let ramMul: Double
        if hints.ramGb < 4 { ramMul = 0.3 }
        else if hints.ramGb < 8 { ramMul = 0.7 }
        else { ramMul = 1.0 }

        let npuBonus: Double = hints.hasNpu ? 1.4 : 1.0

        let raw = gpuBase * cpuMul * ramMul * npuBonus
        return (raw * 10).rounded() / 10
    }

    /// Best-effort introspection on iOS / macOS via sysctl + ProcessInfo.
    public static func detectDeviceHints() -> DeviceCapabilityHints {
        let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        let ramGb = Int(Double(physicalMemoryBytes) / (1024.0 * 1024.0 * 1024.0))
        let cores = ProcessInfo.processInfo.activeProcessorCount

        let cpuClass: CpuClass
        if cores >= 8 { cpuClass = .high }
        else if cores >= 4 { cpuClass = .mid }
        else { cpuClass = .low }

        // Apple Silicon Macs + iPhones with M-series / A-series chips
        // have unified-memory architectures. We treat them as the
        // `appleSilicon` class — the heuristic uses gpuBase = 40.
        // Older Intel Macs report `appleSilicon` if the runtime is on
        // arm64; we rely on `arch == arm64` as the signal.
        let gpuClass: GpuClass = isAppleSilicon() ? .appleSilicon : .integrated

        // NPU detection: every Apple Silicon device since A11 has the
        // Neural Engine, and every Intel Mac since 2020 has none. Use
        // arch as a proxy.
        let hasNpu = isAppleSilicon()

        return DeviceCapabilityHints(
            hasNpu: hasNpu,
            ramGb: ramGb,
            gpuClass: gpuClass,
            cpuClass: cpuClass
        )
    }

    private static func isAppleSilicon() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}

/// Lifecycle mode the SDK enters on `start()`. JSON-serialized as a
/// lower-cased dash string for cross-platform parity (`ok` /
/// `offload-only` / `too-weak`).
public enum PrecheckMode: String, Sendable, Codable, Equatable {
    case ok
    case offloadOnly = "offload-only"
    case tooWeak = "too-weak"
}

/// Mirrors the Kotlin `DeviceCapabilityHints` and TS interface.
public struct DeviceCapabilityHints: Sendable, Codable, Equatable {
    public let hasNpu: Bool
    public let ramGb: Int
    public let gpuClass: GpuClass
    public let cpuClass: CpuClass

    public init(hasNpu: Bool, ramGb: Int, gpuClass: GpuClass, cpuClass: CpuClass) {
        self.hasNpu = hasNpu
        self.ramGb = ramGb
        self.gpuClass = gpuClass
        self.cpuClass = cpuClass
    }
}

public enum GpuClass: String, Sendable, Codable, Equatable {
    case none
    case integrated
    case discrete
    case appleSilicon = "apple-silicon"
}

public enum CpuClass: String, Sendable, Codable, Equatable {
    case low
    case mid
    case high
}
