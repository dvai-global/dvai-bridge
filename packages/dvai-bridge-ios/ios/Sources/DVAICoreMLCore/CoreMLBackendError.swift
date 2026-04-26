import Foundation

public enum CoreMLBackendError: Error, LocalizedError, Sendable {
    case modelLoadFailed(reason: String)
    case tokenizerLoadFailed(reason: String)
    case stateInitFailed(reason: String)
    case generationFailed(reason: String)
    case unsupportedModelFormat(reason: String)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let r): return "CoreML model load failed: \(r)"
        case .tokenizerLoadFailed(let r): return "Tokenizer load failed: \(r)"
        case .stateInitFailed(let r): return "MLState init failed: \(r)"
        case .generationFailed(let r): return "Generation failed: \(r)"
        case .unsupportedModelFormat(let r): return "Unsupported model format: \(r)"
        }
    }
}
