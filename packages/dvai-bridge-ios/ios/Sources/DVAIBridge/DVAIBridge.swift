import Foundation
import Combine
#if !COCOAPODS
import DVAILlamaCore
#endif
#if !COCOAPODS
import DVAIFoundationCore
#endif
#if !COCOAPODS
import DVAICoreMLCore
#endif

/// The iOS SDK entry-point. Use the `shared` singleton or construct an instance
/// for test isolation. All methods are async-throws and dispatch to the active
/// backend's PluginState under the hood. Capacitor-free: no Capacitor headers
/// are imported anywhere.
public actor DVAIBridge {
    public static let shared = DVAIBridge()

    /// Active backend handle. The CoreML state is stored as `Any` so this
    /// enum itself doesn't need an `@available` gate (the package's macOS
    /// floor is .v14 but `CoreMLPluginState` requires macOS 15). All access
    /// to the CoreML state happens inside `if #available(macOS 15.0, *)`.
    private enum BackendInstance {
        case llama(PluginState)
        #if !COCOAPODS
        // Foundation backend uses Apple's `FoundationModels` (iOS 26+),
        // whose import emits implicit autolink directives for private
        // frameworks (`SwiftUICore`, `UIUtilities`, `CoreAudioTypes`)
        // that non-Apple products cannot link directly. Under SwiftPM
        // the consumer's app target IS an allowed client of those
        // frameworks, so the link succeeds; under CocoaPods the link
        // happens inside the pod's framework target, which isn't.
        // Excluded here; selecting `.foundation` at runtime under a
        // CocoaPods build throws DVAIBridgeError.backendUnavailable.
        case foundation(FoundationPluginState)
        #endif
        case coreml(Any)
    }

    private var active: BackendInstance?
    private var activeKind: BackendKind?
    private var activeBaseUrl: String?
    private let downloader = ModelDownloader()
    internal let progressBroadcaster = ProgressBroadcaster()

    public init() {}

    // MARK: - Lifecycle

    public func start(_ config: DVAIBridgeConfig) async throws -> BoundServer {
        if let activeBaseUrl, let activeKind {
            throw DVAIBridgeError.alreadyStarted(currentBackend: activeKind, baseUrl: activeBaseUrl)
        }

        let resolved = try BackendSelector.resolve(config.backend, config: config)
        let opts = config.toCoreOpts()

        let result: [String: Any]
        let backend: BackendInstance

        progressBroadcaster.emit(ProgressEvent(phase: .load))

        switch resolved {
        case .auto:
            // BackendSelector.resolve never returns .auto; keep the compiler happy
            throw DVAIBridgeError.configurationInvalid(reason: "BackendSelector returned .auto unexpectedly")
        case .llama:
            let state = PluginState()
            do {
                result = try await state.start(opts: opts)
            } catch {
                progressBroadcaster.emit(ProgressEvent(phase: .error, message: error.localizedDescription))
                throw DVAIBridgeError.modelLoadFailed(reason: error.localizedDescription)
            }
            backend = .llama(state)
        case .foundation:
            #if !COCOAPODS
            let state = FoundationPluginState()
            do {
                result = try await state.start(opts: opts)
            } catch {
                progressBroadcaster.emit(ProgressEvent(phase: .error, message: error.localizedDescription))
                throw DVAIBridgeError.backendError(underlying: error.localizedDescription)
            }
            backend = .foundation(state)
            #else
            throw DVAIBridgeError.backendUnavailable(
                .foundation,
                reason: "Foundation Models backend is not available in CocoaPods builds of dvai-bridge — Apple's FoundationModels framework triggers private-framework autolink directives that CocoaPods consumers cannot link. Use SwiftPM if your app needs the Foundation backend, or use .llama or .coreml instead."
            )
            #endif
        case .coreml:
            // iOS 18.1 floor of this package already satisfies CoreMLPluginState's
            // iOS 18.0 requirement, but macOS 14 (the package floor) does not
            // satisfy its macOS 15.0 requirement — gate explicitly.
            if #available(macOS 15.0, *) {
                let state = CoreMLPluginState()
                do {
                    result = try await state.start(opts: opts)
                } catch {
                    progressBroadcaster.emit(ProgressEvent(phase: .error, message: error.localizedDescription))
                    throw DVAIBridgeError.backendUnavailable(.coreml, reason: error.localizedDescription)
                }
                backend = .coreml(state)
            } else {
                throw DVAIBridgeError.backendUnavailable(.coreml, reason: "Requires macOS 15+")
            }
        }

        let server = try BoundServer(coreResult: result, backend: resolved)
        self.active = backend
        self.activeKind = resolved
        self.activeBaseUrl = server.baseUrl

        progressBroadcaster.emit(ProgressEvent(phase: .ready))

        let serverCopy = server
        await MainActor.run {
            DVAIBridgeReactiveStateRegistry.shared.state(for: self).didStart(serverCopy)
        }
        return server
    }

    public func stop() async throws {
        guard let backend = active else {
            return  // idempotent
        }
        do {
            switch backend {
            case .llama(let state):
                try await state.stop()
            #if !COCOAPODS
            case .foundation(let state):
                try await state.stop()
            #endif
            case .coreml(let any):
                // Always gated — macOS 14 can never have stored a coreml state
                // here (start() rejects it), so this branch is unreachable on
                // pre-15 macOS, but the availability check is required by the
                // type system.
                if #available(macOS 15.0, *) {
                    if let state = any as? CoreMLPluginState {
                        try await state.stop()
                    }
                }
            }
        } catch {
            // Even if stop() throws, clear state — caller can't usefully retry
            self.active = nil
            self.activeKind = nil
            self.activeBaseUrl = nil
            await MainActor.run {
                DVAIBridgeReactiveStateRegistry.shared.state(for: self).didStop()
            }
            throw DVAIBridgeError.backendError(underlying: error.localizedDescription)
        }
        self.active = nil
        self.activeKind = nil
        self.activeBaseUrl = nil
        await MainActor.run {
            DVAIBridgeReactiveStateRegistry.shared.state(for: self).didStop()
        }
    }

    // MARK: - Status

    public struct StatusInfo: Sendable, Equatable {
        public let running: Bool
        public let backend: BackendKind?
        public let baseUrl: String?
    }

    public func status() -> StatusInfo {
        StatusInfo(
            running: active != nil,
            backend: activeKind,
            baseUrl: activeBaseUrl
        )
    }

    // MARK: - Progress observation

    public nonisolated var progressPublisher: AnyPublisher<ProgressEvent, Never> {
        progressBroadcaster.publisher
    }

    public nonisolated var progressStream: AsyncStream<ProgressEvent> {
        progressBroadcaster.makeStream()
    }

    @discardableResult
    public nonisolated func addProgressListener(
        _ cb: @escaping @Sendable (ProgressEvent) -> Void
    ) -> CancellationToken {
        progressBroadcaster.addCallback(cb)
    }

    // MARK: - Model management (delegates to ModelDownloader)

    public struct DownloadOptions: Sendable {
        public var url: URL
        public var sha256: String
        public var destFilename: String?
        public var headers: [String: String]
        public init(url: URL, sha256: String, destFilename: String? = nil, headers: [String: String] = [:]) {
            self.url = url
            self.sha256 = sha256
            self.destFilename = destFilename
            self.headers = headers
        }
    }

    public struct DownloadResult: Sendable, Equatable {
        public let path: String
        public let cached: Bool
        public init(path: String, cached: Bool) {
            self.path = path
            self.cached = cached
        }
    }

    public func downloadModel(_ opts: DownloadOptions) async throws -> DownloadResult {
        let dest = opts.destFilename ?? opts.url.lastPathComponent
        progressBroadcaster.emit(ProgressEvent(phase: .download))
        do {
            let coreResult = try await downloader.downloadModel(
                url: opts.url,
                expectedSha256: opts.sha256,
                destFilename: dest,
                headers: opts.headers,
                onProgress: { [weak self] (received: Int64, total: Int64?) in
                    let percent: Double? = total.flatMap { $0 > 0 ? (Double(received) / Double($0)) * 100.0 : nil }
                    self?.progressBroadcaster.emit(ProgressEvent(
                        phase: .download,
                        bytesReceived: received,
                        bytesTotal: total,
                        percent: percent
                    ))
                }
            )
            progressBroadcaster.emit(ProgressEvent(phase: .verify))
            return DownloadResult(path: coreResult.path, cached: coreResult.cached)
        } catch {
            progressBroadcaster.emit(ProgressEvent(phase: .error, message: error.localizedDescription))
            if case ModelDownloader.DownloadError.checksumMismatch = error {
                throw DVAIBridgeError.checksumMismatch
            }
            throw DVAIBridgeError.downloadFailed(reason: error.localizedDescription)
        }
    }

    public func listCachedModels() async throws -> [CachedModelInfoSwift] {
        try await downloader.listCachedModels()
    }

    public func deleteCachedModel(filename: String) async throws {
        try await downloader.deleteCachedModel(filename: filename)
    }

    public func cacheDir() async throws -> String {
        try await downloader.cacheDirPath()
    }
}
