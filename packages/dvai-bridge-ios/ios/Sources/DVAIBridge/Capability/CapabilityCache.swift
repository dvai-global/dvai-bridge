import Foundation

/// JSON-file-backed capability cache living under
/// `Application Support/dvai-bridge/capability.json`. Mirrors the TS-side
/// `NodeFsCapabilityCache` in `packages/dvai-bridge-core/src/capability/cache.ts`
/// so the same on-disk format round-trips between native and JS layers
/// running on the same Mac (Mac Catalyst / Electron).
public actor CapabilityCache {
    private let fileURL: URL
    private var cache: [String: CapabilityScore]?

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("capability.json", isDirectory: false)
    }

    public func get(_ key: CapabilityCacheKey) async -> CapabilityScore? {
        let map = await load()
        return map[Self.diskKey(key)]
    }

    public func set(_ score: CapabilityScore) async throws {
        var map = await load()
        let key = CapabilityCacheKey(modelId: score.modelId, libraryVersion: score.libraryVersion)
        map[Self.diskKey(key)] = score
        cache = map
        try await save()
    }

    public func list() async -> [CapabilityScore] {
        let map = await load()
        return Array(map.values)
    }

    public func clear() async throws {
        cache = [:]
        try await save()
    }

    private func load() async -> [String: CapabilityScore] {
        if let cache = cache { return cache }
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: CapabilityScore].self, from: data) {
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

    /// Cache key on-disk: `${modelId}|${libraryVersion}`.
    static func diskKey(_ key: CapabilityCacheKey) -> String {
        "\(key.modelId)|\(key.libraryVersion)"
    }
}

/// Resolves the canonical Application Support directory for dvai-bridge
/// caches (capability + pairings + device-id). Matches the iOS / Mac
/// Catalyst path documented in
/// `docs/migration/v2.4-to-v3.0.md` (Operational notes).
public enum DVAIBridgeSupportDirectory {
    public static func resolve() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("dvai-bridge", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
