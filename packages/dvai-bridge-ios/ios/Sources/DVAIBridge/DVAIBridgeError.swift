import Foundation

public enum DVAIBridgeError: Error, LocalizedError, Sendable {
    case notStarted
    case alreadyStarted(currentBackend: BackendKind, baseUrl: String)
    case configurationInvalid(reason: String)
    case backendUnavailable(BackendKind, reason: String)
    case modelLoadFailed(reason: String)
    case downloadFailed(reason: String)
    case checksumMismatch
    case backendError(underlying: String)

    public var errorDescription: String? {
        switch self {
        case .notStarted:
            return "DVAIBridge has not been started. Call DVAIBridge.shared.start(...) first."
        case .alreadyStarted(let backend, let baseUrl):
            return "DVAIBridge is already running with backend \(backend) at \(baseUrl). Call stop() before starting a new session."
        case .configurationInvalid(let reason):
            return "Configuration invalid: \(reason)"
        case .backendUnavailable(let backend, let reason):
            return "Backend \(backend) is unavailable on this device: \(reason)"
        case .modelLoadFailed(let reason):
            return "Model load failed: \(reason)"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .checksumMismatch:
            return "Downloaded file's SHA-256 didn't match the expected value. The file has been deleted from the cache."
        case .backendError(let msg):
            return "Backend error: \(msg)"
        }
    }
}
