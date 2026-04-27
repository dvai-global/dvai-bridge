package co.deepvoiceai.bridge.litert.core.Internal

import co.deepvoiceai.bridge.litert.core.LiteRTBackendError
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Orchestrates [LiteRTEngineApi] + [HFTokenizerJson] + [LiteRTSampler]
 * into a single autoregressive generate() call.
 *
 * Mirrors `CoreMLGenerator.swift` (iOS) — same prefill+decode unification:
 * each [LiteRTEngineApi.runStep] returns logits for the *next* token
 * (position kv+1), so after feeding all prompt tokens the last logits
 * give the first generated token. We do NOT re-feed `prompt.last()` —
 * that would double-count it in the KV cache.
 *
 * Concurrency: this class is suspend-only; long blocking native calls
 * (`engine.runStep`) are wrapped in `withContext(Dispatchers.Default)` so
 * the caller's coroutine doesn't pin the main thread. Caller must
 * serialize calls behind a mutex (see [LiteRTHandlers.generatorMutex]).
 */
internal class LiteRTGenerator(
    private val engine: LiteRTEngineApi,
    private val tokenizer: HFTokenizerJson,
    private val sampler: LiteRTSampler,
    private val maxNewTokens: Int,
) {

    /**
     * Tokenize [prompt], run the prefill+decode loop, and return the
     * decoded completion (without re-emitting the prompt). Stops on EOS or
     * once [maxNewTokens] generated tokens have been produced.
     *
     * Throws [LiteRTBackendError.GenerationFailed] on empty prompt or
     * native errors propagated from [engine].
     */
    suspend fun generate(prompt: String): String = withContext(Dispatchers.Default) {
        val promptTokens = tokenizer.encode(prompt)
        if (promptTokens.isEmpty()) {
            throw LiteRTBackendError.GenerationFailed("prompt tokenized to empty list")
        }

        val generated = mutableListOf<Int>()

        // Prefill: feed each prompt token, advancing kv position. After
        // the last prompt token, `lastLogits` predicts the FIRST output
        // token — no separate "decode kickoff" step needed.
        var lastLogits = engine.runStep(promptTokens[0], kvCachePosition = 0)
        var kvPos = 1
        for (i in 1 until promptTokens.size) {
            lastLogits = engine.runStep(promptTokens[i], kvCachePosition = kvPos)
            kvPos += 1
        }

        var nextToken = sampler.sample(lastLogits)
        var produced = 0
        while (produced < maxNewTokens) {
            if (nextToken == engine.eosTokenId) break
            generated.add(nextToken)
            produced += 1
            // Stop early if we already hit the cap — saves one wasted
            // forward pass that would just be discarded.
            if (produced >= maxNewTokens) break
            lastLogits = engine.runStep(nextToken, kvCachePosition = kvPos)
            kvPos += 1
            nextToken = sampler.sample(lastLogits)
        }

        tokenizer.decode(generated, skipSpecialTokens = true)
    }
}
