package co.deepvoiceai.bridge

import co.deepvoiceai.bridge.license.LicenseStatus

/**
 * Result of a successful [DVAIBridge.start] call. Mirrors the iOS DVAIBridge
 * `BoundServer` struct + the Capacitor JS shim's StartResult.
 *
 * @param baseUrl       Full base URL of the embedded OpenAI-compatible server,
 *                      including the `/v1` suffix. Example:
 *                      `"http://127.0.0.1:38883/v1"`.
 * @param port          Port the HTTP server actually bound to (port-fallback may
 *                      have moved it past [StartOptions.httpBasePort]).
 * @param backend       The backend that actually loaded — useful when [StartOptions]
 *                      set [BackendKind.Auto] and the consumer wants to know what
 *                      was picked.
 * @param modelId       Stable identifier for the loaded model. Surfaced in the
 *                      `model` field of every OpenAI response.
 * @param licenseStatus v3.3 — outcome of the offline JWT license check that
 *                      ran during [DVAIBridge.start]. Null when the validator
 *                      didn't run (legacy callers, missing context). Production
 *                      starts always carry a non-null status here; failure modes
 *                      throw before this struct is produced.
 */
data class BoundServer(
    val baseUrl: String,
    val port: Int,
    val backend: BackendKind,
    val modelId: String,
    val licenseStatus: LicenseStatus? = null,
)

/** Read-only status snapshot returned by [DVAIBridge.status]. */
data class StatusInfo(
    val running: Boolean,
    val baseUrl: String? = null,
    val backend: BackendKind? = null,
    val modelId: String? = null,
)
