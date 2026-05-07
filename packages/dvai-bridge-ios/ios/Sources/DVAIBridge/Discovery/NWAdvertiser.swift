import Foundation
import Network

/// Advertises THIS device on Bonjour as a `_dvai-bridge._tcp` service
/// using `NWListener`. The TXT record carries the fields documented in
/// the design spec section 4.2.
@available(iOS 14.0, macOS 11.0, *)
public actor NWAdvertiser {
    public struct Advertisement: Sendable, Equatable {
        public let deviceId: String
        public let deviceName: String
        public let dvaiVersion: String
        public let port: Int
        public let secure: Bool
        public let loadedModels: [String]
        public let capability: [String: Double]

        public init(
            deviceId: String,
            deviceName: String,
            dvaiVersion: String,
            port: Int,
            secure: Bool = false,
            loadedModels: [String] = [],
            capability: [String: Double] = [:]
        ) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.dvaiVersion = dvaiVersion
            self.port = port
            self.secure = secure
            self.loadedModels = loadedModels
            self.capability = capability
        }
    }

    private var listener: NWListener?
    private var advertised: Advertisement?

    public init() {}

    /// Start advertising. Idempotent — if already advertising, the new
    /// advertisement supersedes the old one.
    public func start(_ ad: Advertisement) async throws {
        await stop()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Use a TCP listener bound to the same advertisement port. The
        // listener itself doesn't have to actually accept connections —
        // the upstream embedded HTTP server does that on the same port.
        // We just need the Bonjour record present.
        let port = NWEndpoint.Port(rawValue: UInt16(ad.port)) ?? .any
        let listener = try NWListener(using: params, on: port)
        // Important: we're advertising a service that ANOTHER socket
        // (the Telegraph HTTP server) actually listens on. NWListener
        // would normally accept these connections — null-route them
        // by just cancelling immediately. The Bonjour TXT record is
        // what we care about.
        listener.newConnectionHandler = { conn in
            conn.cancel()
        }

        let txt = Self.makeTxtRecord(ad)
        listener.service = NWListener.Service(
            name: ad.deviceName,
            type: DVAIBridgeMDNS.serviceType,
            domain: nil,
            txtRecord: txt
        )

        listener.start(queue: .global(qos: .utility))
        self.listener = listener
        self.advertised = ad
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        advertised = nil
    }

    public func currentAdvertisement() -> Advertisement? {
        advertised
    }

    /// Build the Bonjour TXT record for an advertisement. Mirrors the
    /// fields documented in the design spec section 4.2.
    static func makeTxtRecord(_ ad: Advertisement) -> NWTXTRecord {
        var rec = NWTXTRecord()
        rec["deviceId"] = ad.deviceId
        rec["deviceName"] = ad.deviceName
        rec["dvaiVersion"] = ad.dvaiVersion
        rec["port"] = String(ad.port)
        rec["secure"] = ad.secure ? "1" : "0"
        rec["models"] = ad.loadedModels.joined(separator: ",")
        if let capData = try? JSONSerialization.data(withJSONObject: ad.capability),
           let capStr = String(data: capData, encoding: .utf8) {
            rec["capability"] = capStr
        }
        return rec
    }
}
