/*
 * License-file discovery for the iOS SDK.
 *
 * Mirrors `packages/dvai-bridge-core/src/license/discovery.ts` but with
 * iOS-native locations (Bundle resources, Documents directory, App Group
 * containers) in place of the JS side's CWD-based filesystem walk.
 *
 * Priority order (first hit wins):
 *
 *   1. `LicenseDiscoveryOptions.token` — inline JWT string. Useful when
 *      the host app fetches its license over the network at runtime
 *      and wants to inject the result without touching disk.
 *
 *   2. `LicenseDiscoveryOptions.path` — explicit file path. Useful for
 *      tests or for hosts that store the .jwt outside the standard
 *      locations. If this path is set but the file isn't there or
 *      isn't readable, this is a real miss (we do NOT silently fall
 *      through to auto-discovery) — same semantics as the JS side.
 *
 *   3. `DVAI_LICENSE_PATH` env var. Operator-supplied path; helpful
 *      for CI / TestFlight where you don't want to ship the .jwt in
 *      the bundle. Misses fall through to (5).
 *
 *   4. `DVAI_LICENSE_TOKEN` env var. Inline JWT in the environment.
 *
 *   5. `dvai-license.jwt` resource in `Bundle.main`. The dev-friendly
 *      happy path: add the file to the app's "Copy Bundle Resources"
 *      phase, the SDK picks it up automatically.
 *
 *   6. `Application Support/dvai-bridge/dvai-license.jwt` in the app's
 *      sandbox. Useful for licenses fetched after install (e.g. via
 *      an in-app purchase flow).
 *
 *   7. `Documents/dvai-license.jwt`. Last-resort fallback — visible
 *      via iTunes File Sharing if the app opts in, so handy for
 *      side-loading a license during development.
 *
 * Returning `nil` means "no license token found"; the validator treats
 * that as the free-tier case (after the dev-mode bypass).
 */
import Foundation

/// Default filename the SDK looks for in Bundle / Documents / App Support.
/// Chosen to be self-documenting and to encourage commit-to-vcs (so the
/// license travels with the code).
public let DVAI_DEFAULT_LICENSE_FILENAME = "dvai-license.jwt"

public struct LicenseDiscoveryOptions: Sendable {
    /// Pre-loaded JWT string (skips all filesystem lookups).
    public var token: String?
    /// Explicit path to load from. Overrides auto-discovery.
    public var path: String?
    /// App Group identifier to also search (e.g. for shared licenses
    /// across an app + extension). Optional; default `nil` skips the
    /// App Group lookup.
    public var appGroupIdentifier: String?

    public init(
        token: String? = nil,
        path: String? = nil,
        appGroupIdentifier: String? = nil
    ) {
        self.token = token
        self.path = path
        self.appGroupIdentifier = appGroupIdentifier
    }
}

/// Best-effort load of a license JWT. Returns the raw token string +
/// source description on success, or nil on miss. Errors during loading
/// (file not found, permission denied) collapse to nil — the
/// validator's responsibility is to handle the no-license case
/// gracefully, not the discovery layer's.
///
/// Source descriptions are surfaced in `LicenseStatus.freeProd.reason`
/// for debug, and shown in dashboards so the developer can see which
/// of the seven locations resolved.
public func discoverLicenseToken(
    options: LicenseDiscoveryOptions = LicenseDiscoveryOptions()
) -> (token: String, source: String)? {
    // 1. Explicit token wins.
    if let token = options.token, !token.isEmpty {
        return (token.trimmingCharacters(in: .whitespacesAndNewlines), "options.token")
    }

    // 2. Explicit path.
    if let path = options.path, !path.isEmpty {
        if let loaded = tryLoadFromPath(path) {
            return (loaded, path)
        }
        return nil // explicit miss — do NOT fall through
    }

    // 3. Env-var path. Use `envVar` (libc getenv) so DVAI_LICENSE_PATH
    //    mutated mid-process — e.g. by tests — is picked up.
    if let envPath = envVar("DVAI_LICENSE_PATH") {
        if let loaded = tryLoadFromPath(envPath) {
            return (loaded, "DVAI_LICENSE_PATH=\(envPath)")
        }
    }

    // 4. Env-var inline token.
    if let envToken = envVar("DVAI_LICENSE_TOKEN") {
        return (
            envToken.trimmingCharacters(in: .whitespacesAndNewlines),
            "DVAI_LICENSE_TOKEN env var"
        )
    }

    // 5. Bundle resource (dvai-license.jwt next to the app's other
    //    bundled resources).
    if let bundleURL = Bundle.main.url(forResource: "dvai-license", withExtension: "jwt") {
        if let loaded = tryLoadFromPath(bundleURL.path) {
            return (loaded, "Bundle.main resource dvai-license.jwt")
        }
    }

    // 6. Application Support / dvai-bridge / dvai-license.jwt.
    if let appSupportURL = (try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    )) {
        let candidate = appSupportURL
            .appendingPathComponent("dvai-bridge", isDirectory: true)
            .appendingPathComponent(DVAI_DEFAULT_LICENSE_FILENAME)
        if let loaded = tryLoadFromPath(candidate.path) {
            return (loaded, candidate.path)
        }
    }

    // 7. Documents directory.
    if let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        let candidate = docsURL.appendingPathComponent(DVAI_DEFAULT_LICENSE_FILENAME)
        if let loaded = tryLoadFromPath(candidate.path) {
            return (loaded, candidate.path)
        }
    }

    // 8. (Optional) App Group container, if configured.
    if let groupId = options.appGroupIdentifier, !groupId.isEmpty {
        if let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupId)?
            .appendingPathComponent(DVAI_DEFAULT_LICENSE_FILENAME) {
            if let loaded = tryLoadFromPath(groupURL.path) {
                return (loaded, groupURL.path)
            }
        }
    }

    return nil
}

/// Read a file at `path` and return its trimmed UTF-8 contents, or
/// nil on any error (missing / permission / encoding).
private func tryLoadFromPath(_ path: String) -> String? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return nil }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
