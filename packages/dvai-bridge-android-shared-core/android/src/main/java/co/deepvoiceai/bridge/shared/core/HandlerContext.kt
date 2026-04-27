package co.deepvoiceai.bridge.shared.core

/**
 * Per-request context passed to every [DvaiHandlers] method.
 *
 * Both fields are surfaced in the OpenAI-compatible JSON responses (e.g.
 * the `model` field of `/v1/chat/completions` results) so the consumer
 * sees a stable name regardless of which backend handled the request.
 */
data class HandlerContext(val modelId: String, val backendName: String)
