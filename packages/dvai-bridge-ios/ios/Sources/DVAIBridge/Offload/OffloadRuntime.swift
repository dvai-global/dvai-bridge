import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Bundles together the iOS-native offload state for one running
/// `DVAIBridge` instance: discovery, advertiser, capability cache,
/// pairing store + policy. Created on `start()` when
/// `OffloadConfig.enabled == true`; torn down on `stop()`.
@available(iOS 14.0, macOS 11.0, *)
public actor OffloadRuntime {
    public let config: OffloadConfig
    public let supportDirectory: URL
    public let deviceIDStore: DeviceIDStore
    public let capabilityCache: CapabilityCache
    public let pairingStore: PairingStore
    public let pairingPolicy: PairingPolicy
    public let discovery: NWBrowserDiscovery
    public let advertiser: NWAdvertiser
    private var started = false

    public init(config: OffloadConfig, supportDirectory: URL? = nil) throws {
        self.config = config
        self.supportDirectory = try supportDirectory ?? DVAIBridgeSupportDirectory.resolve()
        self.deviceIDStore = DeviceIDStore(directory: self.supportDirectory)
        self.capabilityCache = CapabilityCache(directory: self.supportDirectory)
        self.pairingStore = PairingStore(directory: self.supportDirectory)
        self.pairingPolicy = PairingPolicy(
            store: pairingStore,
            expireAfterDays: config.expireAfterDays
        )
        self.discovery = NWBrowserDiscovery()
        self.advertiser = NWAdvertiser()
    }

    /// Bring up the discovery + advertiser. Idempotent.
    /// `boundServer` provides the port + version we advertise.
    public func start(boundServer: BoundServer, libraryVersion: String) async throws {
        guard !started else { return }
        started = true

        if config.discoverLAN {
            await discovery.start()
            let deviceId = try deviceIDStore.get()
            let deviceName = Self.resolveDeviceName()
            try await advertiser.start(
                NWAdvertiser.Advertisement(
                    deviceId: deviceId,
                    deviceName: deviceName,
                    dvaiVersion: libraryVersion,
                    port: boundServer.port,
                    secure: false,
                    loadedModels: boundServer.modelId.isEmpty ? [] : [boundServer.modelId],
                    capability: [:]
                )
            )
        }
    }

    /// Tear down. Idempotent.
    public func stop() async {
        guard started else { return }
        started = false
        await discovery.stop()
        await advertiser.stop()
        await pairingPolicy.shutdown()
    }

    public func isRunning() -> Bool { started }

    /// Surface the pairing-request stream. Called by
    /// `DVAIBridge.shared.pairingRequests`.
    public nonisolated func pairingRequestStream() -> AsyncStream<PairingRequest> {
        pairingPolicy.requestStream
    }

    public nonisolated func discoveryEventStream() -> AsyncStream<NWBrowserDiscovery.Event> {
        discovery.events
    }

    private static func resolveDeviceName() -> String {
        #if canImport(UIKit) && !os(macOS)
        if Thread.isMainThread {
            return UIDevice.current.name
        }
        // Best-effort: hostname is fine off-main-thread.
        return ProcessInfo.processInfo.hostName
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}
