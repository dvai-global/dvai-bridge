package co.deepvoiceai.bridge.shared.core

import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.json.JsonElement

/** What a [DvaiHandlers] method returns. */
sealed class HandlerResponse {
    data class Json(val status: Int, val body: JsonElement) : HandlerResponse()
    data class Sse(val flow: Flow<String>) : HandlerResponse()
    data class Error(val status: Int, val message: String) : HandlerResponse()
}
