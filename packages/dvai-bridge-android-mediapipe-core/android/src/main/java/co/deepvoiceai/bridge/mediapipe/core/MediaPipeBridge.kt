package co.deepvoiceai.bridge.mediapipe.core

import android.content.Context
import android.graphics.BitmapFactory
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.genai.llminference.GraphOptions
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession

/**
 * Test seam over Google's MediaPipe LLM Inference engine. Concrete
 * [MediaPipeBridge] implements this; [MediaPipeHandlers] takes the interface
 * so unit tests can substitute a canned-response fake without loading a real
 * `.task` model bundle.
 *
 * Concurrency: implementations need NOT be thread-safe — [MediaPipeHandlers]
 * serializes all calls behind its own mutex. The session-based MediaPipe API
 * (0.10.16+) tolerates parallel sessions on a shared `LlmInference` engine in
 * principle, but the handler still serializes for predictable ordering and
 * to keep the contract identical between the two backends.
 */
interface MediaPipeBridgeApi {
    /**
     * Synchronous prompt completion. If [images] is non-empty the engine must
     * have been built with `visionEnabled = true`; otherwise MediaPipe will
     * throw at session-creation time. Images are supplied as raw encoded bytes
     * (PNG/JPEG/etc.); the implementation converts them to [MPImage] internally.
     */
    fun completePrompt(prompt: String, images: List<ByteArray> = emptyList()): String

    /**
     * Asynchronous prompt completion. The supplied callback fires per partial
     * chunk; the second arg is `true` on the final fragment. Returns a handle
     * the caller can [AutoCloseable.close] to release the per-call session
     * once the stream finishes (or is cancelled). Images are supplied as raw
     * encoded bytes (PNG/JPEG/etc.); the implementation converts internally.
     */
    fun completePromptAsync(
        prompt: String,
        images: List<ByteArray> = emptyList(),
        onPartial: (partial: String, done: Boolean) -> Unit,
    ): AutoCloseable
}

/**
 * Kotlin wrapper around the MediaPipe `tasks-genai:0.10.33` LLM Inference API.
 *
 * Architecture:
 *
 *  - One long-lived [LlmInference] engine per bridge instance (lazy-initialized
 *    so JVM unit tests using the [MediaPipeBridgeApi] fake never trigger
 *    native loading).
 *  - One [LlmInferenceSession] per request — sessions are cheap and isolate
 *    state (chunks, images) between calls. The session is closed in `finally`
 *    on the sync path and via the returned [AutoCloseable] on the async path.
 *  - For vision-capable models, [visionEnabled] wires
 *    `setMaxNumImages(maxImages)` into the engine and
 *    `setEnableVisionModality(true)` into the session graph options. Without
 *    those flags MediaPipe rejects `addImage` calls.
 *  - `generateResponseAsync` accepts a per-call `(partial, done) -> Unit`
 *    progress listener directly in 0.10.33 — the AtomicReference<lambda> swap
 *    workaround required by 0.10.14 is gone.
 *
 * Note on the `@Suppress("DEPRECATION")`: as of `tasks-genai:0.10.27` Google
 * marks `LlmInference` / `LlmInferenceSession` / `GraphOptions` deprecated in
 * favour of LiteRT-LM. Phase 1 explicitly targets the MediaPipe APIs because
 * LiteRT-LM was not stable when the spec was frozen; migration is a separate
 * task tracked outside this milestone.
 */
@Suppress("DEPRECATION")
class MediaPipeBridge(
    private val context: Context,
    private val modelPath: String,
    private val maxTokens: Int = 2048,
    private val visionEnabled: Boolean = false,
    private val maxImages: Int = 1,
) : MediaPipeBridgeApi, AutoCloseable {

    private val inference: LlmInference by lazy {
        val builder = LlmInference.LlmInferenceOptions.builder()
            .setModelPath(modelPath)
            .setMaxTokens(maxTokens)
        if (visionEnabled) {
            builder.setMaxNumImages(maxImages)
        }
        LlmInference.createFromOptions(context, builder.build())
    }

    @Volatile private var inferenceInitialized: Boolean = false

    private fun engine(): LlmInference {
        val ref = inference
        inferenceInitialized = true
        return ref
    }

    private fun sessionOptions(): LlmInferenceSession.LlmInferenceSessionOptions {
        val builder = LlmInferenceSession.LlmInferenceSessionOptions.builder()
        if (visionEnabled) {
            builder.setGraphOptions(
                GraphOptions.builder().setEnableVisionModality(true).build(),
            )
        }
        return builder.build()
    }

    /**
     * Decode a list of raw image byte arrays (PNG/JPEG/etc.) into [MPImage]
     * instances for consumption by the MediaPipe session. Conversion is eager
     * (all images decoded before the session is opened) so a decode failure
     * surfaces before any native resources are acquired.
     */
    private fun bytesToMpImages(images: List<ByteArray>): List<MPImage> =
        images.map { bytes ->
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                ?: throw IllegalArgumentException("BitmapFactory.decodeByteArray returned null")
            BitmapImageBuilder(bitmap).build()
        }

    override fun completePrompt(prompt: String, images: List<ByteArray>): String {
        val mpImages = bytesToMpImages(images)
        val session = LlmInferenceSession.createFromOptions(engine(), sessionOptions())
        try {
            // MediaPipe requires the text query chunk to be added before any
            // images for vision-capable graphs.
            session.addQueryChunk(prompt)
            for (img in mpImages) {
                session.addImage(img)
            }
            return session.generateResponse()
        } finally {
            try {
                session.close()
            } catch (_: Throwable) { /* idempotent */ }
        }
    }

    override fun completePromptAsync(
        prompt: String,
        images: List<ByteArray>,
        onPartial: (String, Boolean) -> Unit,
    ): AutoCloseable {
        val mpImages = bytesToMpImages(images)
        val session = LlmInferenceSession.createFromOptions(engine(), sessionOptions())
        try {
            session.addQueryChunk(prompt)
            for (img in mpImages) {
                session.addImage(img)
            }
            // Per-call ProgressListener in 0.10.16+. Lambda matches Kotlin's
            // SAM conversion for `ProgressListener<String>`: (partial, done).
            session.generateResponseAsync { partial, done ->
                onPartial(partial, done)
            }
        } catch (t: Throwable) {
            try {
                session.close()
            } catch (_: Throwable) { /* idempotent */ }
            throw t
        }
        return AutoCloseable {
            try {
                session.close()
            } catch (_: Throwable) { /* idempotent — best-effort cleanup */ }
        }
    }

    override fun close() {
        if (inferenceInitialized) {
            try {
                inference.close()
            } catch (_: Throwable) { /* idempotent */ }
        }
    }
}
