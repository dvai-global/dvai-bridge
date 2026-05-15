import Foundation

public struct BoundServer: Sendable, Equatable {
    public let baseUrl: String
    public let port: Int
    public let backend: BackendKind
    public let modelId: String
    /// v3.2.2 — the license status the validator reported at startup.
    /// `nil` when `DVAIBridge.start(_:)` was called without going through
    /// the license gate (e.g. legacy test fixtures). `commercial` / `trial`
    /// on the paid path; `freeDev` on debug / simulator. The two failure
    /// cases (`freeProd` / `freeExpired`) never make it here because
    /// `start(_:)` throws `LicenseRequiredError` before constructing
    /// `BoundServer`.
    public let licenseStatus: LicenseStatus?

    public init(
        baseUrl: String,
        port: Int,
        backend: BackendKind,
        modelId: String,
        licenseStatus: LicenseStatus? = nil
    ) {
        self.baseUrl = baseUrl
        self.port = port
        self.backend = backend
        self.modelId = modelId
        self.licenseStatus = licenseStatus
    }

    /// Construct from the underlying core PluginState's `[String: Any]` result.
    internal init(coreResult: [String: Any], backend: BackendKind, licenseStatus: LicenseStatus? = nil) throws {
        guard let baseUrl = coreResult["baseUrl"] as? String,
              let port = (coreResult["port"] as? Int) ?? (coreResult["port"] as? NSNumber)?.intValue
        else {
            throw DVAIBridgeError.backendError(underlying: "core PluginState returned malformed start result")
        }
        let modelId = (coreResult["modelId"] as? String) ?? ""
        self.init(baseUrl: baseUrl, port: port, backend: backend, modelId: modelId, licenseStatus: licenseStatus)
    }

    /// v3.2.2 — derive a copy with the license status attached.
    internal func with(licenseStatus: LicenseStatus?) -> BoundServer {
        BoundServer(baseUrl: baseUrl, port: port, backend: backend, modelId: modelId, licenseStatus: licenseStatus)
    }
}
