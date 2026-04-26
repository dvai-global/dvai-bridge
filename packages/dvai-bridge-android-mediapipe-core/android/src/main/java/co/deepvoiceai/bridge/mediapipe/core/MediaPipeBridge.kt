package co.deepvoiceai.bridge.mediapipe.core

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback

/**
 * Test seam over Google's LiteRT-LM Engine. Concrete [MediaPipeBridge]
 * implements this; [MediaPipeHandlers] takes the interface so unit tests can
 * substitute a canned-response fake without loading a real `.litertlm` model.
 *
 * Concurrency: implementations need NOT be thread-safe — [MediaPipeHandlers]
 * serializes all calls behind its own mutex.
 */
interface MediaPipeBridgeApi {
    /**
     * Synchronous prompt completion. If [images] is non-empty the engine must
     * have been built with `visionEnabled = true`; otherwise LiteRT-LM will
     * throw at conversation creation or message-send time. Images are supplied
     * as raw encoded bytes (PNG/JPEG/etc.).
     */
    fun completePrompt(prompt: String, images: List<ByteArray> = emptyList()): String

    /**
     * Asynchronous prompt completion. The supplied callback fires per partial
     * chunk; the second arg is `true` on the final fragment. Returns a handle
     * the caller can [AutoCloseable.close] to release the per-call conversation
     * once the stream finishes (or is cancelled). Images are supplied as raw
     * encoded bytes (PNG/JPEG/etc.).
     */
    fun completePromptAsync(
        prompt: String,
        images: List<ByteArray> = emptyList(),
        onPartial: (partial: String, done: Boolean) -> Unit,
    ): AutoCloseable
}

/**
 * Kotlin wrapper around the LiteRT-LM `litertlm-android:0.10.2` Engine API.
 * Replaces the deprecated `com.google.mediapipe:tasks-genai` MediaPipe bridge
 * (Phase 3B, Tasks 18-19).
 *
 * Architecture:
 *
 *  - One long-lived [Engine] per bridge instance (lazy-initialized so JVM unit
 *    tests using the [MediaPipeBridgeApi] fake never trigger native loading).
 *    [engine.initialize()] is called inside the lazy block; this is the heavy
 *    model-load step (~10 s) and must be called off the main thread.
 *  - One [Conversation] per request — LiteRT-LM Conversations are stateful and
 *    multi-turn, so we create a fresh one per call and close it after to
 *    maintain the same stateless-request semantics as the old session model.
 *  - Vision is enabled at the engine level via [EngineConfig.visionBackend].
 *    There is no per-conversation vision flag (unlike the old
 *    `GraphOptions.setEnableVisionModality`).
 *
 * API deviations from the migration doc (§3) based on actual bytecode inspection:
 *  - [Message] has no `.text` property — text is accessed through
 *    `message.contents.contents`, which is a `List<Content>`. Text parts are
 *    `Content.Text` items; their text fields are joined to form the response.
 *  - [EngineConfig] DOES have `maxNumImages: Int?` and `maxNumTokens: Int?`
 *    fields in the actual 0.10.2 artifact — the migration doc §5 risk for
 *    setMaxNumImages is not applicable; the field exists and is used here.
 *  - [Engine] does not accept Android `Context` — per migration doc §4, Context
 *    is only needed for optional path derivation. The constructor keeps `context`
 *    for API compatibility and future use (e.g. `context.cacheDir.path`).
 *
 * Model file format: LiteRT-LM uses `.litertlm` bundles, not `.task`. Existing
 * `.task` models must be re-converted; see the migration notes for details.
 */
class MediaPipeBridge(
    @Suppress("UNUSED_PARAMETER") private val context: Context,
    private val modelPath: String,
    private val maxTokens: Int = 2048,
    private val visionEnabled: Boolean = false,
    private val maxImages: Int = 1,
) : MediaPipeBridgeApi, AutoCloseable {

    private val engine: Engine by lazy {
        val cfg = EngineConfig(
            modelPath = modelPath,
            // Vision is enabled at the engine level by supplying a visionBackend.
            // GPU() is the standard choice; null disables vision modality.
            visionBackend = if (visionEnabled) Backend.GPU() else null,
            // maxNumImages: EngineConfig does have this field in 0.10.2
            // (migration doc §5 TBD is resolved — field exists in actual artifact).
            maxNumImages = if (visionEnabled) maxImages else null,
            // maxNumTokens maps to the old setMaxTokens(int) option.
            maxNumTokens = maxTokens,
        )
        val e = Engine(cfg)
        e.initialize()
        e
    }

    @Volatile private var engineInitialized: Boolean = false

    private fun engine(): Engine {
        val ref = engine
        engineInitialized = true
        return ref
    }

    private fun newConversation(): Conversation =
        engine().createConversation()

    /**
     * Build a [Contents] value combining the text prompt with any image bytes.
     * [Content.ImageBytes] accepts raw PNG/JPEG bytes directly — no MPImage
     * wrapping required (migration doc §2). The vararg [Contents.of] overload
     * is used to avoid a spurious unchecked-cast warning from the list overload.
     */
    private fun buildContents(prompt: String, images: List<ByteArray>): Contents {
        val parts = mutableListOf<Content>(Content.Text(prompt))
        for (bytes in images) {
            parts.add(Content.ImageBytes(bytes))
        }
        return Contents.of(parts)
    }

    /**
     * Extract text from a [Message] response.
     *
     * [Message] has no `.text` shortcut in the 0.10.2 public API. Text is
     * accessed via `message.contents.contents` (a `List<Content>`). All
     * `Content.Text` items are joined; non-text parts (images, audio, tool
     * responses) are silently ignored, matching the expected LLM response shape.
     */
    private fun Message.extractText(): String =
        contents.contents
            .filterIsInstance<Content.Text>()
            .joinToString("") { it.text }

    override fun completePrompt(prompt: String, images: List<ByteArray>): String {
        val msgContents = buildContents(prompt, images)
        val conversation = newConversation()
        try {
            // sendMessage is the single-call replacement for the old
            // addQueryChunk + addImage + generateResponse triple (migration doc §3).
            val message = conversation.sendMessage(msgContents)
            return message.extractText()
        } finally {
            try {
                conversation.close()
            } catch (_: Throwable) { /* idempotent */ }
        }
    }

    override fun completePromptAsync(
        prompt: String,
        images: List<ByteArray>,
        onPartial: (String, Boolean) -> Unit,
    ): AutoCloseable {
        val msgContents = buildContents(prompt, images)
        val conversation = newConversation()
        try {
            // MessageCallback replaces the old ProgressListener<String> callback.
            // onMessage fires per partial token; onDone signals completion.
            // (migration doc §3 streaming: callback form maps 1:1 to our contract)
            conversation.sendMessageAsync(
                msgContents,
                object : MessageCallback {
                    override fun onMessage(message: Message) {
                        onPartial(message.extractText(), false)
                    }

                    override fun onDone() {
                        onPartial("", true)
                    }

                    override fun onError(throwable: Throwable) {
                        // Surface the error: re-throw on the callback thread so
                        // that the engine's internal executor propagates it.
                        throw RuntimeException("LiteRT-LM streaming error", throwable)
                    }
                },
            )
        } catch (t: Throwable) {
            try {
                conversation.close()
            } catch (_: Throwable) { /* idempotent */ }
            throw t
        }
        return AutoCloseable {
            try {
                conversation.close()
            } catch (_: Throwable) { /* idempotent — best-effort cleanup */ }
        }
    }

    override fun close() {
        if (engineInitialized) {
            try {
                engine.close()
            } catch (_: Throwable) { /* idempotent */ }
        }
    }
}
