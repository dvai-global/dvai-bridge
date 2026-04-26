import Foundation

/// Inference backend used by `DVAIBridge.shared.start(...)`.
public enum BackendKind: String, Sendable, Codable, CaseIterable {
    /// Resolve the best available backend at runtime.
    case auto
    /// llama.cpp via Metal (iOS) — the broad-compatibility default.
    case llama
    /// Apple Foundation Models (LanguageModelSession). Requires iOS 26+ at runtime.
    case foundation
    /// CoreML / ANE — initial release ships a stub that throws `notYetImplemented`.
    case coreml
}
