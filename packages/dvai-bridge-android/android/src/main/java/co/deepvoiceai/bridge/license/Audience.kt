package co.deepvoiceai.bridge.license

import android.content.Context
import android.content.pm.ApplicationInfo

/**
 * Runtime audience + platform + dev-mode detection for the Android SDK.
 *
 * Kotlin port of `packages/dvai-bridge-core/src/license/audience.ts`.
 * The semantics are identical to the JS side but the platform APIs
 * differ — audience is read from [Context.getPackageName] rather than
 * `window.location.hostname`, and dev-mode is detected via
 * `BuildConfig.DEBUG` + `ApplicationInfo.FLAG_DEBUGGABLE` rather than
 * hostname heuristics.
 *
 * "Audience" on Android = the host app's package name (e.g.
 * `"com.acme.app"`). License JWTs bind to package names exactly like
 * iOS bundle ids; subdomain-style `*.acme.com` wildcards work for
 * domain-tail matching too.
 *
 * "Dev mode" detection bypasses license enforcement entirely so
 * developers don't need a license to run the SDK on a debug build.
 * This matches the JS-side `detectDevMode()` behaviour.
 */

/** Detect the current SDK platform identifier. Always [DvaiPlatform.ANDROID]. */
fun detectPlatform(): DvaiPlatform = DvaiPlatform.ANDROID

/**
 * Detect the current audience string the license must bind. Returns
 * the host app's package name from [Context.getPackageName].
 *
 * Returns null only if [context] is null — in practice this never
 * happens because [LicenseValidator] requires a non-null context at
 * construction.
 */
fun detectAudience(context: Context?): String? = context?.packageName

/**
 * Detect whether the SDK is running in a developer environment where
 * license enforcement should be bypassed. The bypass list is
 * intentionally generous: blocking a developer mid-`./gradlew installDebug`
 * with a license-not-found error would be hostile.
 *
 * Precedence (highest first):
 *   1. `DVAI_FORCE_PROD=1` env var — production mode forced, overrides DEBUG.
 *   2. `DVAI_FORCE_DEV=1` env var — dev mode forced.
 *   3. [hostBuildConfigDebug] (a `BuildConfig.DEBUG` value passed in by the
 *      host app via [co.deepvoiceai.bridge.StartOptions]) — dev mode.
 *   4. [ApplicationInfo.FLAG_DEBUGGABLE] on the host app — dev mode.
 *   5. Otherwise production, license required.
 *
 * @param context              Application context — used to read
 *                             `ApplicationInfo.FLAG_DEBUGGABLE`.
 * @param hostBuildConfigDebug The host app's `BuildConfig.DEBUG`, passed in
 *                             explicitly because the validator lives in a
 *                             library module whose own `BuildConfig.DEBUG`
 *                             never reflects the host app's state. Pass null
 *                             to skip this check.
 */
fun detectDevMode(
    context: Context?,
    hostBuildConfigDebug: Boolean? = null,
): DevModeResult {
    // 1. Explicit env-var overrides win — these mirror the JS side so the
    //    same DVAI_FORCE_PROD / DVAI_FORCE_DEV semantics work in CI/test
    //    contexts on any platform.
    val forceProd = System.getenv("DVAI_FORCE_PROD")
    if (forceProd == "1" || forceProd == "true") {
        return DevModeResult(isDev = false, reason = "DVAI_FORCE_PROD set")
    }
    val forceDev = System.getenv("DVAI_FORCE_DEV")
    if (forceDev == "1" || forceDev == "true") {
        return DevModeResult(isDev = true, reason = "DVAI_FORCE_DEV set")
    }

    // 2. Host app's BuildConfig.DEBUG (explicit, preferred). When the host
    //    passes a non-null value we treat it as authoritative — the host
    //    knows whether they're a debug build better than we do. When null,
    //    we fall through to the manifest-flag heuristic.
    when (hostBuildConfigDebug) {
        true -> return DevModeResult(isDev = true, reason = "BuildConfig.DEBUG=true")
        false -> return DevModeResult(isDev = false, reason = "BuildConfig.DEBUG=false (host-supplied)")
        null -> { /* fall through */ }
    }

    // 3. ApplicationInfo.FLAG_DEBUGGABLE — set on debug builds and on apps
    //    with `android:debuggable="true"` in the manifest. Fallback when the
    //    host hasn't wired their BuildConfig.DEBUG through to StartOptions.
    if (context != null) {
        val flags = context.applicationInfo.flags
        if ((flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            return DevModeResult(isDev = true, reason = "ApplicationInfo.FLAG_DEBUGGABLE set")
        }
    }

    return DevModeResult(isDev = false, reason = "production-class environment")
}

/** Outcome of [detectDevMode]. */
data class DevModeResult(val isDev: Boolean, val reason: String)

/**
 * Decide whether a license-payload `aud` entry matches the current
 * runtime audience. Supports exact match and `*.example.com` wildcard
 * matching for subdomain binding. Returns the matched `aud` pattern
 * on success so it can be recorded for audit, or null on miss.
 *
 * Match rules (identical to the JS side):
 *   - `"foo"` matches `"foo"` exactly
 *   - `"*.example.com"` matches `"example.com"` AND any `"<sub>.example.com"`
 *   - `"*"` matches any non-empty audience (intentionally permissive; use
 *     for trial/site licenses that span all of a customer's deployments)
 *
 * Runtime audience of `null` matches `"*"` only.
 */
fun matchAudience(runtimeAudience: String?, audClaim: List<String>): String? {
    if (runtimeAudience == null) {
        return if (audClaim.contains("*")) "*" else null
    }
    val runtime = runtimeAudience.lowercase()
    for (pattern in audClaim) {
        val p = pattern.lowercase()
        if (p == "*") return pattern // permissive wildcard
        if (p == runtime) return pattern // exact match
        if (p.startsWith("*.")) {
            val suffix = p.substring(2)
            if (runtime == suffix || runtime.endsWith(".$suffix")) {
                return pattern
            }
        }
    }
    return null
}
