package co.deepvoiceai.bridge.litert.core.Internal

import co.deepvoiceai.bridge.litert.core.LiteRTBackendError
import com.google.ai.edge.litert.Accelerator
import com.google.ai.edge.litert.CompiledModel
import com.google.ai.edge.litert.TensorBuffer
import com.google.ai.edge.litert.TensorType
import java.io.File

/**
 * Test seam over the LiteRT [CompiledModel]. Concrete [LiteRTEngine] runs
 * the real native runtime; [LiteRTGenerator]'s mock test substitutes a
 * canned-logits fake without loading a .tflite.
 */
internal interface LiteRTEngineApi {
    /** Vocab size (= length of the FloatArray returned by [runStep]). */
    val vocabSize: Int

    /** EOS id in the model's vocab — generator uses it to terminate decode. */
    val eosTokenId: Int

    /**
     * Run a single forward pass with [token] at position [kvCachePosition].
     * Returns the logits row for the next-token prediction (length = [vocabSize]).
     * Throws [LiteRTBackendError.GenerationFailed] on native failure.
     */
    fun runStep(token: Int, kvCachePosition: Int): FloatArray

    /** Release native resources. Idempotent. */
    fun close()
}

/**
 * Wraps Google's LiteRT [CompiledModel] for a stateful Llama-style
 * autoregressive checkpoint. Drives single-token decoding via named-tensor
 * `run(inputs, outputs, signature)` calls.
 *
 * Why not use LiteRT-LM? We deliberately depend on bare `litert` (see
 * `android/build.gradle` top-of-file comment), so the KV-cache / sampler
 * loop is implemented here in Kotlin. The Llama-style .tflite checkpoints
 * we target carry the cache as graph-internal state, exposed through
 * named inputs/outputs that the runtime maintains across calls within one
 * [CompiledModel] instance — same shape Apple's CoreML stateful Llama
 * checkpoints follow on iOS (see `CoreMLEngine.swift`).
 *
 * Tensor convention (auto-detected at init via [CompiledModel.getInputTensorType]):
 *  - [inputName]    `input_ids`     INT32 [1, 1]                       (default, overridable)
 *  - [causalMaskName] `causal_mask` FLOAT [1, 1, 1, kv_len]            (optional)
 *  - [outputName]   `logits`        FLOAT [1, 1, vocab] or [1, vocab]  (auto)
 *
 * If the model declares no `causal_mask` input we silently skip writing
 * it — many simpler stateful checkpoints don't expose one.
 *
 * This class is NOT thread-safe. [LiteRTHandlers] serializes all calls
 * behind a mutex; do the same in any other call site.
 */
internal class LiteRTEngine(
    modelPath: String,
    private val inputName: String = "input_ids",
    private val causalMaskName: String = "causal_mask",
    private val outputName: String = "logits",
    /** Surface override so the handler / config layer can lift it from start opts. */
    @Suppress("UNUSED_PARAMETER")
    private val contextSize: Int = 2048,
    eosTokenId: Int,
    accelerator: Accelerator = Accelerator.CPU,
) : LiteRTEngineApi, AutoCloseable {

    private val model: CompiledModel
    override val vocabSize: Int
    override val eosTokenId: Int = eosTokenId
    private val hasCausalMask: Boolean
    private val causalMaskRank: Int
    private val inputIsInt64: Boolean

    init {
        val f = File(modelPath)
        if (!f.isFile) {
            throw LiteRTBackendError.ModelLoadFailed("model file not found at $modelPath")
        }

        model = try {
            CompiledModel.create(modelPath, CompiledModel.Options(accelerator))
        } catch (t: Throwable) {
            throw LiteRTBackendError.ModelLoadFailed("CompiledModel.create failed: ${t.message ?: t::class.java.simpleName}")
        }

        // Validate the input_ids tensor exists and capture its rank/dtype
        // for the writeInt path. We don't enforce shape == [1,1] here —
        // the model owns its declared signature; we just feed [token] as
        // a 1-element IntArray and let the runtime broadcast / error out.
        val inputType = try {
            model.getInputTensorType(inputName)
        } catch (t: Throwable) {
            // If the named-tensor lookup fails, the consumer's checkpoint
            // doesn't follow our convention. Fail fast with a precise
            // message — silent fallback to default signature would only
            // surface the real shape mismatch deep inside nativeRun().
            model.close()
            throw LiteRTBackendError.ModelLoadFailed(
                "input tensor '$inputName' not found on model (override via litertInputName opt). " +
                    "Cause: ${t.message ?: t::class.java.simpleName}",
            )
        }
        // Both INT32 and INT64 input_ids are seen on Llama-style
        // checkpoints in the wild (Llama-3 typically int32, some Gemma
        // exports int64). We dispatch to `writeInt` vs `writeLong` based
        // on the declared element type at runStep time, so both shapes
        // round-trip cleanly through LiteRT's strict dtype check.
        if (inputType.elementType != TensorType.ElementType.INT &&
            inputType.elementType != TensorType.ElementType.INT64
        ) {
            model.close()
            throw LiteRTBackendError.ModelLoadFailed(
                "input tensor '$inputName' has unsupported elementType=${inputType.elementType}; expected INT or INT64",
            )
        }
        inputIsInt64 = inputType.elementType == TensorType.ElementType.INT64

        // causal_mask is optional — many simpler checkpoints don't expose it.
        // Probe via a try/catch on getInputTensorType since the LiteRT API
        // doesn't have a non-throwing "does this input exist?" call.
        var maskRank = 0
        val maskPresent = try {
            val maskType = model.getInputTensorType(causalMaskName)
            maskRank = maskType.layout?.rank ?: 0
            true
        } catch (_: Throwable) {
            false
        }
        hasCausalMask = maskPresent
        causalMaskRank = maskRank

        // Discover logits rank + vocab size by inspecting the output
        // tensor type. Handles both [1, 1, V] (Llama-3 style) and
        // [1, V] (some Gemma exports).
        val outputType = try {
            model.getOutputTensorType(outputName)
        } catch (t: Throwable) {
            model.close()
            throw LiteRTBackendError.ModelLoadFailed(
                "output tensor '$outputName' not found on model (override via litertOutputName opt). " +
                    "Cause: ${t.message ?: t::class.java.simpleName}",
            )
        }
        val outDims = outputType.layout?.dimensions ?: emptyList()
        vocabSize = when (outDims.size) {
            3 -> outDims[2]   // [1, 1, V] — Llama-3 style
            2 -> outDims[1]   // [1, V]    — some Gemma exports
            else -> {
                model.close()
                throw LiteRTBackendError.ModelLoadFailed(
                    "output tensor '$outputName' has unsupported rank=${outDims.size}; expected 2 or 3 with vocab as last dim",
                )
            }
        }
        if (vocabSize <= 0) {
            model.close()
            throw LiteRTBackendError.ModelLoadFailed(
                "output tensor '$outputName' reports non-positive vocab size: $vocabSize",
            )
        }
    }

    override fun runStep(token: Int, kvCachePosition: Int): FloatArray {
        val inputs = mutableMapOf<String, TensorBuffer>()
        val outputs = mutableMapOf<String, TensorBuffer>()
        val opened = mutableListOf<TensorBuffer>()
        try {
            // input_ids: [1, 1] with the new token. writeInt vs writeLong
            // is selected from the declared element type captured at init.
            val inputBuf = model.createInputBuffer(inputName)
            opened.add(inputBuf)
            if (inputIsInt64) {
                inputBuf.writeLong(longArrayOf(token.toLong()))
            } else {
                inputBuf.writeInt(intArrayOf(token))
            }
            inputs[inputName] = inputBuf

            // causal_mask: [1, 1, 1, kvCachePosition+1] all-zeros if the
            // model declares one. Zero = unmasked, large negative = masked;
            // for a single-token decode step every prior position is visible.
            // LiteRT only exposes writeFloat for FP tensors — even if the
            // declared dtype is FP16, the runtime accepts FP32 input and
            // converts internally. (HF model converts also produce FP32
            // causal_masks more often than FP16 in 2026 conversions.)
            if (hasCausalMask && causalMaskRank > 0) {
                val kvLen = maxOf(1, kvCachePosition + 1)
                val maskBuf = model.createInputBuffer(causalMaskName)
                opened.add(maskBuf)
                // Zero-fill with size = product of the buffer's logical
                // dimensions (we pass the full kvLen-sized buffer; LiteRT
                // resizes dynamic-axis tensors based on writeFloat length).
                maskBuf.writeFloat(FloatArray(kvLen))
                inputs[causalMaskName] = maskBuf
            }

            val outputBuf = model.createOutputBuffer(outputName)
            opened.add(outputBuf)
            outputs[outputName] = outputBuf

            try {
                model.run(inputs, outputs)
            } catch (t: Throwable) {
                throw LiteRTBackendError.GenerationFailed(
                    "model.run failed at kvPos=$kvCachePosition token=$token: ${t.message ?: t::class.java.simpleName}",
                )
            }

            val raw = outputBuf.readFloat()
            // For rank-3 logits we want the LAST row (the prediction for
            // the *next* token). With a [1, 1, V] shape there's only one
            // row anyway so raw IS the next-token logits — but if the
            // checkpoint produces [1, T, V] for a multi-token prefill we'd
            // want raw.takeLast(V). We default to the last-V slice for
            // robustness.
            return if (raw.size == vocabSize) {
                raw
            } else {
                val start = raw.size - vocabSize
                if (start < 0) {
                    throw LiteRTBackendError.GenerationFailed(
                        "logits buffer length ${raw.size} is smaller than vocabSize $vocabSize",
                    )
                }
                raw.copyOfRange(start, raw.size)
            }
        } finally {
            // Release every per-call TensorBuffer (createInputBuffer +
            // createOutputBuffer allocate fresh native handles each call).
            for (buf in opened) {
                runCatching { buf.close() }
            }
        }
    }

    override fun close() {
        runCatching { model.close() }
    }
}
