import Foundation
import Combine

/// SwiftUI-friendly reactive state. Exposes lifecycle and progress as
/// `@Published` properties on the main actor.
@MainActor
public final class DVAIBridgeReactiveState: ObservableObject {
    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var baseUrl: String? = nil
    @Published public private(set) var port: Int? = nil
    @Published public private(set) var currentBackend: BackendKind? = nil
    @Published public private(set) var lastProgress: ProgressEvent? = nil

    internal init() {}

    internal func didStart(_ server: BoundServer) {
        isReady = true
        baseUrl = server.baseUrl
        port = server.port
        currentBackend = server.backend
    }

    internal func didStop() {
        isReady = false
        baseUrl = nil
        port = nil
        currentBackend = nil
    }

    internal func didReceiveProgress(_ event: ProgressEvent) {
        lastProgress = event
    }
}

extension DVAIBridge {
    /// Main-actor-isolated reactive state for SwiftUI views. Subsequent
    /// accesses return the same object — pin it as `@StateObject` upstream.
    @MainActor
    public var reactive: DVAIBridgeReactiveState {
        DVAIBridgeReactiveStateRegistry.shared.state(for: self)
    }
}

/// Per-DVAIBridge-instance registry of ReactiveState objects. Actors can't
/// own MainActor-isolated state directly, so the registry lives on the
/// MainActor and keys by `ObjectIdentifier(bridge)`.
@MainActor
internal final class DVAIBridgeReactiveStateRegistry {
    static let shared = DVAIBridgeReactiveStateRegistry()
    private var states: [ObjectIdentifier: DVAIBridgeReactiveState] = [:]

    func state(for bridge: DVAIBridge) -> DVAIBridgeReactiveState {
        let id = ObjectIdentifier(bridge)
        if let existing = states[id] { return existing }
        let new = DVAIBridgeReactiveState()
        states[id] = new
        // Forward all progress events into the state on the main actor.
        Task { @MainActor [weak new] in
            for await event in bridge.progressStream {
                new?.didReceiveProgress(event)
            }
        }
        return new
    }
}
