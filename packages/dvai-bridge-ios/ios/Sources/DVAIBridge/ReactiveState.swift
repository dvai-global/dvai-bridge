import Foundation
import Combine

/// SwiftUI-friendly reactive state. Exposes lifecycle and progress as
/// observable properties on the main actor.
///
/// ## Distribution-channel asymmetry
///
/// - **Under SwiftPM** (`Package.swift`): full `ObservableObject` +
///   `@Published` API. Drop into a SwiftUI view as `@StateObject` /
///   `@ObservedObject` and the view re-renders automatically when any
///   property changes.
/// - **Under CocoaPods** (`DVAIBridge.podspec`): `ObservableObject`
///   conformance and the `@Published` wrappers are intentionally OMITTED.
///   The properties remain `public private(set) var` and are still
///   readable; observers must subscribe to `stateChanges` (the always-
///   available `Combine` publisher below) instead of using SwiftUI's
///   property-wrapper integration.
///
/// **Why the asymmetry?** Xcode 26 / iOS 26 SDK's static linker emits
/// an implicit link directive for `SwiftUICore` (a private framework
/// non-Apple products cannot link) for *any* module that conforms a type
/// to `ObservableObject` — even if the module never imports SwiftUI.
/// Linking `SwiftUICore` from a non-Apple framework fails with
/// "cannot link directly with 'SwiftUICore' because product being built
/// is not an allowed client of it". CocoaPods bundles all of dvai-bridge
/// into a single Swift module, so the trigger lands on every consumer's
/// link line. SwiftPM, by contrast, builds dvai-bridge as a library
/// dynamically resolved at the consumer's link line where SwiftUICore
/// access *is* allowed (because the consumer's app IS an allowed client),
/// so the same conformance compiles fine.
///
/// CocoaPods SwiftUI consumers wanting reactive view updates should:
///
///     @State private var snapshot = DVAIBridgeSnapshot()
///     ...
///     .onReceive(DVAIBridge.shared.reactive.stateChanges) { _ in
///         snapshot = DVAIBridgeSnapshot.from(DVAIBridge.shared.reactive)
///     }
///
/// Or wrap the reactive object in a small SwiftUI-side adapter that
/// conforms to `ObservableObject` themselves (since their app target
/// IS an allowed SwiftUICore client).
@MainActor
public final class DVAIBridgeReactiveState {
    #if COCOAPODS
    public private(set) var isReady: Bool = false {
        didSet { stateChangesSubject.send() }
    }
    public private(set) var baseUrl: String? = nil {
        didSet { stateChangesSubject.send() }
    }
    public private(set) var port: Int? = nil {
        didSet { stateChangesSubject.send() }
    }
    public private(set) var currentBackend: BackendKind? = nil {
        didSet { stateChangesSubject.send() }
    }
    public private(set) var lastProgress: ProgressEvent? = nil {
        didSet { stateChangesSubject.send() }
    }
    #else
    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var baseUrl: String? = nil
    @Published public private(set) var port: Int? = nil
    @Published public private(set) var currentBackend: BackendKind? = nil
    @Published public private(set) var lastProgress: ProgressEvent? = nil
    #endif

    private let stateChangesSubject = PassthroughSubject<Void, Never>()

    /// Combine publisher that fires whenever any of the state properties
    /// changes. Available in both SwiftPM and CocoaPods builds — SwiftPM
    /// consumers usually use `ObservableObject` directly via SwiftUI's
    /// property wrappers, but this publisher remains available as a
    /// non-SwiftUI alternative.
    public nonisolated var stateChanges: AnyPublisher<Void, Never> {
        stateChangesSubject.eraseToAnyPublisher()
    }

    internal init() {}

    internal func didStart(_ server: BoundServer) {
        isReady = true
        baseUrl = server.baseUrl
        port = server.port
        currentBackend = server.backend
        #if !COCOAPODS
        // Under SwiftPM the @Published wrappers handle change publishing
        // automatically; we still emit on stateChangesSubject so non-SwiftUI
        // observers (e.g. UIKit code paths) can subscribe to it uniformly.
        stateChangesSubject.send()
        #endif
    }

    internal func didStop() {
        isReady = false
        baseUrl = nil
        port = nil
        currentBackend = nil
        #if !COCOAPODS
        stateChangesSubject.send()
        #endif
    }

    internal func didReceiveProgress(_ event: ProgressEvent) {
        lastProgress = event
        #if !COCOAPODS
        stateChangesSubject.send()
        #endif
    }
}

#if !COCOAPODS
extension DVAIBridgeReactiveState: ObservableObject {}
#endif

extension DVAIBridge {
    /// Main-actor-isolated reactive state. Subsequent accesses return the
    /// same object — under SwiftPM, pin it as `@StateObject` upstream;
    /// under CocoaPods, observe the `stateChanges` publisher.
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
