package co.deepvoiceai.dvaibridge.mediapipe

import android.content.Context
import com.google.mediapipe.tasks.core.OutputHandler
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import java.util.concurrent.atomic.AtomicReference

/**
 * Test seam over Google's MediaPipe LLM Inference engine. Concrete
 * [MediaPipeBridge] implements this; [MediaPipeHandlers] takes the interface
 * so unit tests can substitute a canned-response fake without loading a real
 * `.task` model bundle.
 *
 * Concurrency: implementations need NOT be thread-safe — [MediaPipeHandlers]
 * serializes all calls behind its own mutex because `LlmInference` itself is
 * single-shot per engine instance.
 */
interface MediaPipeBridgeApi {
    /** Synchronous prompt completion. Returns generated text or throws. */
    fun completePrompt(prompt: String): String

    /**
     * Asynchronous prompt completion. The supplied callback fires per partial
     * chunk; the second arg is `true` on the final fragment. Returns a handle
     * the caller can [AutoCloseable.close] to drop the per-call listener once
     * the stream finishes (or is cancelled).
     */
    fun completePromptAsync(
        prompt: String,
        onPartial: (partial: String, done: Boolean) -> Unit,
    ): AutoCloseable
}

/**
 * Kotlin wrapper around the MediaPipe `tasks-genai:0.10.14` LLM Inference API.
 *
 * Key API constraints (deviation from the original plan, which was written
 * against a later MediaPipe release):
 *
 *  - `tasks-genai:0.10.14` does NOT expose `LlmInferenceSession`; everything
 *    runs on a single [LlmInference] engine.
 *  - `generateResponseAsync(prompt)` does NOT take a per-call callback — the
 *    streaming `ProgressListener<String>` must be supplied at creation time
 *    via `LlmInferenceOptions.Builder.setResultListener(...)`.
 *
 * To reconcile that with our per-request callback shape, the bridge installs
 * a single forwarding listener at engine-create time and swaps the *active*
 * per-call lambda in [activeListener] under [MediaPipeHandlers]'s mutex
 * before each async call. The forwarding listener delegates to whichever
 * lambda is current; when a request finishes (or its handle is closed) the
 * lambda is cleared so any straggler callbacks become no-ops.
 *
 * Lazy-initialized so JVM unit tests (which use a [MediaPipeBridgeApi] fake)
 * never trigger native loading; [close] is a no-op if the engine was never
 * touched.
 */
class MediaPipeBridge(
    private val context: Context,
    private val modelPath: String,
    private val maxTokens: Int = 2048,
) : MediaPipeBridgeApi, AutoCloseable {
    private val activeListener = AtomicReference<((String, Boolean) -> Unit)?>(null)

    private val inference: LlmInference by lazy {
        val resultListener = OutputHandler.ProgressListener<String> { partial, done ->
            activeListener.get()?.invoke(partial, done)
        }
        LlmInference.createFromOptions(
            context,
            LlmInference.LlmInferenceOptions.builder()
                .setModelPath(modelPath)
                .setMaxTokens(maxTokens)
                .setResultListener(resultListener)
                .build(),
        )
    }

    @Volatile private var inferenceInitialized: Boolean = false

    override fun completePrompt(prompt: String): String {
        // Sync path: clear any leftover listener so the engine doesn't accidentally
        // double-deliver if something earlier left state in place, then run.
        activeListener.set(null)
        val engine = inference.also { inferenceInitialized = true }
        return engine.generateResponse(prompt)
    }

    override fun completePromptAsync(
        prompt: String,
        onPartial: (String, Boolean) -> Unit,
    ): AutoCloseable {
        activeListener.set(onPartial)
        val engine = inference.also { inferenceInitialized = true }
        try {
            engine.generateResponseAsync(prompt)
        } catch (t: Throwable) {
            activeListener.set(null)
            throw t
        }
        return AutoCloseable {
            // Drop the listener slot so any final callbacks post-close are no-ops.
            activeListener.compareAndSet(onPartial, null)
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
