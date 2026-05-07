import Foundation

/// Stable per-install device identifier. Generated once on first call,
/// persisted alongside the capability cache under the same Application
/// Support directory. Used for:
///   - identifying THIS device in mDNS TXT records (LAN discovery).
///   - identifying THIS device in rendezvous-server pairing payloads.
///   - keying the capability cache.
///
/// NOT a privacy hazard: the ID is per-install and per-device-storage,
/// never tied to user identity. Reinstalling the app or wiping app
/// storage produces a fresh ID — that's the right behaviour and matches
/// the TS-side `generateDeviceId` semantics in
/// `packages/dvai-bridge-core/src/capability/deviceId.ts`.
public final class DeviceIDStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var cached: String?

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("device-id.txt", isDirectory: false)
    }

    /// Return the device ID, generating + persisting it on first call.
    public func get() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cached { return cached }

        // Try to load existing
        if let data = try? Data(contentsOf: fileURL),
           let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            cached = raw
            return raw
        }

        // Generate fresh
        let id = Self.generate()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try id.write(to: fileURL, atomically: true, encoding: .utf8)
        cached = id
        return id
    }

    /// Generate a 22-char URL-safe base64 random ID. Mirrors the TS
    /// `generateDeviceId()` shape (16 random bytes, base64url, no
    /// padding) so device IDs round-trip across platforms.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fall back to UUID — still random, just not from SecRandom.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
                .lowercased().prefix(22).description
        }
        return base64UrlEncode(Data(bytes))
    }

    private static func base64UrlEncode(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
