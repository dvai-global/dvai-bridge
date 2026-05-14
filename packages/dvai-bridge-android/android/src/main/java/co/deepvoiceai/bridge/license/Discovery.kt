package co.deepvoiceai.bridge.license

import android.content.Context
import java.io.File

/**
 * License-file discovery for the Android SDK.
 *
 * Kotlin port of `packages/dvai-bridge-core/src/license/discovery.ts`.
 * The discovery priority order mirrors the JS side but the platform-
 * default locations are Android-specific:
 *
 *   1. An explicit string literal passed via [LicenseDiscoveryOptions.token]
 *      — useful for CI / test contexts where reading a file isn't practical.
 *   2. A path passed via [LicenseDiscoveryOptions.path] — the developer
 *      points the SDK at a file they've placed somewhere non-default.
 *   3. The `DVAI_LICENSE_PATH` env var — same as (2) but driven by
 *      process environment, helpful for emulator-based testing.
 *   4. The `DVAI_LICENSE_TOKEN` env var — inline JWT as an alternative
 *      to a file path.
 *   5. The bundled asset `assets/dvai-license.jwt` — the conventional
 *      ship-with-the-APK location. Auto-discovered.
 *   6. The bundled raw resource `R.raw.dvai_license` — alternative
 *      asset location for apps that already use the res/raw/ folder.
 *      Looked up reflectively against the host app's R.raw class.
 *   7. Internal storage `context.filesDir/dvai-license.jwt` — for
 *      apps that drop the license at runtime (e.g. fetched from
 *      a self-hosted endpoint after first launch).
 *
 * Returning `null` means "no license file found"; the validator treats
 * that as the free-prod case, which on Android escalates to a throw via
 * [LicenseValidator.validateAndAssert].
 */

/** Default filename the SDK looks for at every file location. */
const val DEFAULT_LICENSE_FILENAME: String = "dvai-license.jwt"

/** Default raw-resource name (without the `R.raw.` prefix). */
const val DEFAULT_LICENSE_RAW_RESOURCE_NAME: String = "dvai_license"

data class LicenseDiscoveryOptions(
    /** Pre-loaded JWT string (skips all filesystem / asset lookups). */
    val token: String? = null,
    /** Explicit path to load from. Overrides auto-discovery. */
    val path: String? = null,
)

/** Result of a successful discovery; identifies the source for audit logging. */
data class DiscoveredToken(val token: String, val source: String)

/**
 * Best-effort load of a license JWT. Returns the raw token string on
 * success or null on miss. Errors during loading (file not found, asset
 * not present) collapse to null — the validator's responsibility is to
 * handle the no-license case gracefully, not the discovery layer's.
 *
 * Side-effect-free in the sense of "no network calls"; reads from the
 * filesystem and the APK's assets directory only.
 */
fun discoverLicenseToken(
    context: Context,
    opts: LicenseDiscoveryOptions = LicenseDiscoveryOptions(),
): DiscoveredToken? {
    // 1. Explicit token wins.
    if (!opts.token.isNullOrEmpty()) {
        return DiscoveredToken(opts.token.trim(), "config.licenseToken")
    }

    // 2. Explicit path (config option). An explicit path that doesn't load
    //    is a real miss, not a silent fallthrough — matches JS behaviour.
    if (!opts.path.isNullOrEmpty()) {
        val loaded = tryLoadFromPath(opts.path)
        return loaded?.let { DiscoveredToken(it, opts.path) }
    }

    // 3. Env-var path.
    val envPath = System.getenv("DVAI_LICENSE_PATH")
    if (!envPath.isNullOrEmpty()) {
        val loaded = tryLoadFromPath(envPath)
        if (loaded != null) return DiscoveredToken(loaded, "DVAI_LICENSE_PATH=$envPath")
    }

    // 4. Env-var inline token (alternative to file).
    val envToken = System.getenv("DVAI_LICENSE_TOKEN")
    if (!envToken.isNullOrEmpty()) {
        return DiscoveredToken(envToken.trim(), "DVAI_LICENSE_TOKEN env var")
    }

    // 5. Bundled asset: assets/dvai-license.jwt.
    val asset = tryLoadFromAsset(context, DEFAULT_LICENSE_FILENAME)
    if (asset != null) return DiscoveredToken(asset, "assets/$DEFAULT_LICENSE_FILENAME")

    // 6. Bundled raw resource: R.raw.dvai_license (looked up reflectively
    //    against the host app's R class because we can't reference its
    //    R from a library module).
    val raw = tryLoadFromRawResource(context, DEFAULT_LICENSE_RAW_RESOURCE_NAME)
    if (raw != null) return DiscoveredToken(raw, "res/raw/$DEFAULT_LICENSE_RAW_RESOURCE_NAME")

    // 7. Internal storage: filesDir/dvai-license.jwt.
    val internalFile = File(context.filesDir, DEFAULT_LICENSE_FILENAME)
    val internal = tryLoadFromFile(internalFile)
    if (internal != null) return DiscoveredToken(internal, internalFile.absolutePath)

    return null
}

private fun tryLoadFromPath(path: String): String? = tryLoadFromFile(File(path))

private fun tryLoadFromFile(file: File): String? {
    return try {
        if (!file.exists() || !file.isFile) return null
        val text = file.readText(Charsets.UTF_8).trim()
        text.ifEmpty { null }
    } catch (_: Throwable) {
        null
    }
}

private fun tryLoadFromAsset(context: Context, name: String): String? {
    return try {
        context.assets.open(name).use { input ->
            val text = input.readBytes().toString(Charsets.UTF_8).trim()
            text.ifEmpty { null }
        }
    } catch (_: Throwable) {
        null
    }
}

private fun tryLoadFromRawResource(context: Context, name: String): String? {
    return try {
        // Resource ids are dynamic — the library module has no compile-time
        // reference to the host app's R.raw, so look it up by name via
        // Resources.getIdentifier(). Returns 0 if the host app doesn't
        // ship a `res/raw/dvai_license.*` resource, which we treat as a
        // clean miss.
        val resId = context.resources.getIdentifier(name, "raw", context.packageName)
        if (resId == 0) return null
        context.resources.openRawResource(resId).use { input ->
            val text = input.readBytes().toString(Charsets.UTF_8).trim()
            text.ifEmpty { null }
        }
    } catch (_: Throwable) {
        null
    }
}
