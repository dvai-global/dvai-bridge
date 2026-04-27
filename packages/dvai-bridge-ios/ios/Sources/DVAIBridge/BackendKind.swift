import Foundation

/// Inference backend used by `DVAIBridge.shared.start(...)`.
public enum BackendKind: String, Sendable, Codable, CaseIterable {
    /// Resolve the best available backend at runtime.
    case auto
    /// llama.cpp via Metal (iOS) — the broad-compatibility default.
    case llama
    /// Apple Foundation Models (LanguageModelSession). Requires iOS 26+ at runtime.
    /// SwiftPM-only: omitted from CocoaPods builds (the `import FoundationModels`
    /// auto-link directive references private frameworks CocoaPods consumers
    /// cannot link). Selecting this under CocoaPods throws `backendUnavailable`.
    case foundation
    /// CoreML / Apple Neural Engine via `MLModel` + `MLState` (iOS 18+).
    case coreml
    /// MLX — Apple Silicon GPU/Neural Engine via `mlx-swift-lm`. Apple-Silicon
    /// only at runtime; the iOS Simulator on Intel hosts has no MLX device.
    /// Loads HuggingFace MLX-converted checkpoints (e.g.
    /// "mlx-community/Llama-3.2-1B-Instruct-4bit"). SwiftPM-only for the
    /// same reasons as `.foundation` — the mlx-swift-lm transitive deps
    /// don't publish CocoaPods specs.
    case mlx
}
