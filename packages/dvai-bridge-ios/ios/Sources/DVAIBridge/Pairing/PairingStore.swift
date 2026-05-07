import Foundation

/// JSON-file-backed pairing store under
/// `Application Support/dvai-bridge/pairings.json`. Mirrors the TS-side
/// `NodeFsPairingStore` in `packages/dvai-bridge-core/src/pairing/store.ts`.
public actor PairingStore {
    private let fileURL: URL
    private var cache: [String: Pairing]?

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("pairings.json", isDirectory: false)
    }

    public func get(_ peerDeviceId: String) async -> Pairing? {
        let map = await load()
        return map[peerDeviceId]
    }

    public func set(_ pairing: Pairing) async throws {
        var map = await load()
        map[pairing.peerDeviceId] = pairing
        cache = map
        try await save()
    }

    public func list() async -> [Pairing] {
        let map = await load()
        return Array(map.values)
    }

    public func remove(_ peerDeviceId: String) async throws {
        var map = await load()
        map.removeValue(forKey: peerDeviceId)
        cache = map
        try await save()
    }

    public func clear() async throws {
        cache = [:]
        try await save()
    }

    private func load() async -> [String: Pairing] {
        if let cache = cache { return cache }
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Pairing].self, from: data) {
            cache = decoded
            return decoded
        }
        cache = [:]
        return [:]
    }

    private func save() async throws {
        guard let cache = cache else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)
        try data.write(to: fileURL, options: .atomic)
    }
}
