package co.deepvoiceai.bridge.shared.core

/** CORS configuration for the dispatch layer. */
sealed class CorsConfig {
    object Wildcard : CorsConfig()
    data class Exact(val origin: String) : CorsConfig()
    data class Allowlist(val origins: List<String>) : CorsConfig()

    /**
     * Resolve the `Access-Control-Allow-Origin` header value for an incoming
     * request. Returns null when the request origin isn't allowed (callers
     * skip emitting the header in that case).
     */
    fun headerValue(reqOrigin: String?): String? = when (this) {
        is Wildcard -> "*"
        is Exact -> origin
        is Allowlist -> if (reqOrigin != null && origins.contains(reqOrigin)) reqOrigin else null
    }
}
