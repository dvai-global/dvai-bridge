/*
 * Runtime audience + platform + dev-mode detection for the iOS SDK.
 *
 * Mirrors `packages/dvai-bridge-core/src/license/audience.ts`. The
 * semantics are identical; only the platform APIs differ.
 *
 *   - audience  = `Bundle.main.bundleIdentifier` (may be `nil` in some
 *                 unit-test hosts; null is treated like the JS side does
 *                 — only `"*"` aud entries match)
 *   - platform  = always `.ios` from this SDK (the Capacitor consumers
 *                 use the Capacitor SDK, which detects `.capacitor`
 *                 from JS-side; this iOS SDK is for native iOS apps)
 *   - dev mode  = DEBUG build OR simulator OR DVAI_FORCE_DEV=1
 *                 (DVAI_FORCE_PROD=1 overrides DEBUG / simulator)
 */
import Foundation

/// Detect the current SDK platform identifier. Always `.ios` on iOS —
/// Capacitor consumers use a different SDK (the Capacitor plugin's
/// JS-side validator detects `capacitor`). React Native consumers
/// likewise use a different SDK.
public func detectPlatform() -> DvaiPlatform {
    return .ios
}

/// Read an environment variable via C's `getenv` so we observe live
/// updates (`setenv` in tests). `ProcessInfo.environment` caches its
/// dict on Apple's Foundation, which makes per-test env mutation
/// unreliable.
internal func envVar(_ name: String) -> String? {
    guard let cstr = getenv(name) else { return nil }
    let value = String(cString: cstr)
    return value.isEmpty ? nil : value
}

/// Detect the current audience string the license must bind. On iOS
/// this is the running app's bundle identifier (e.g. `"com.acme.app"`).
///
/// Returns `nil` only when no bundle identifier is available — uncommon
/// in production, but possible in some SwiftPM test hosts. Null is
/// handled by the validator: it matches only the `"*"` aud entry.
///
/// An explicit `DVAI_AUDIENCE` environment variable overrides the bundle
/// id (matches the JS-side override; mostly useful for tests).
public func detectAudience() -> String? {
    if let override = envVar("DVAI_AUDIENCE") {
        return override
    }
    if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
        return bundleId
    }
    return nil
}

/// Detect whether the SDK is running in a developer environment where
/// license enforcement should be bypassed. The bypass list is
/// intentionally generous: blocking a developer mid-Xcode-run with a
/// license-not-found error would be hostile.
///
/// Order (first match wins):
///   1. `DVAI_FORCE_PROD=1` → force production (overrides DEBUG +
///      simulator). The host app's CI sets this to exercise license
///      enforcement in non-RELEASE builds.
///   2. `DVAI_FORCE_DEV=1` → force dev. Explicit operator opt-in.
///   3. `#if DEBUG` → dev. Compile-time check — the DEBUG configuration
///      bypasses licensing entirely so the in-Xcode dev loop never
///      surfaces a license error.
///   4. `targetEnvironment(simulator)` → dev. Same intent: a simulator
///      run is by construction a dev environment.
///   5. otherwise → production, license required.
public func detectDevMode() -> (isDev: Bool, reason: String) {
    // 1. Explicit env-var overrides (operator-level, runtime). Use
    //    `envVar` (libc getenv) so DVAI_FORCE_* mutated mid-process —
    //    e.g. by tests — is picked up.
    let forceProd = envVar("DVAI_FORCE_PROD")
    if forceProd == "1" || forceProd == "true" {
        return (false, "DVAI_FORCE_PROD set")
    }
    let forceDev = envVar("DVAI_FORCE_DEV")
    if forceDev == "1" || forceDev == "true" {
        return (true, "DVAI_FORCE_DEV set")
    }

    // 2. DEBUG configuration.
    #if DEBUG
    return (true, "DEBUG build configuration")
    #else
    // 3. Simulator (DEBUG would have already caught most simulator
    //    runs; this branch matters for a Release-configuration build
    //    happening to run on the simulator — rare, but harmless to
    //    bypass).
    #if targetEnvironment(simulator)
    return (true, "iOS Simulator")
    #else
    return (false, "production-class environment")
    #endif
    #endif
}

/// Decide whether a license-payload `aud` entry matches the current
/// runtime audience. Supports exact match and `*.example.com` wildcard
/// matching for subdomain (here: bundle-id-suffix) binding. Returns
/// the matched `aud` pattern on success so it can be recorded for
/// audit, or `nil` on miss.
///
/// Match rules (identical to the JS-side `matchAudience`):
///   - `"foo"` matches `"foo"` exactly (case-insensitive)
///   - `"*.example.com"` matches `"example.com"` AND any
///     `"<sub>.example.com"`
///   - `"*"` matches any non-nil audience (intentionally permissive;
///     used for trial / site licenses that span all of a customer's
///     deployments)
///
/// A `nil` runtime audience matches only `"*"` entries — a build with
/// no bundle identifier can activate any-domain licenses but not
/// bundle-bound ones.
public func matchAudience(runtimeAudience: String?, audClaim: [String]) -> String? {
    guard let runtime = runtimeAudience?.lowercased(), !runtime.isEmpty else {
        return audClaim.contains("*") ? "*" : nil
    }
    for pattern in audClaim {
        let p = pattern.lowercased()
        if p == "*" { return pattern }            // permissive wildcard
        if p == runtime { return pattern }        // exact match
        if p.hasPrefix("*.") {
            let suffix = String(p.dropFirst(2))
            if runtime == suffix || runtime.hasSuffix("." + suffix) {
                return pattern
            }
        }
    }
    return nil
}
