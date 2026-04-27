package co.deepvoiceai.bridge.litert.core.Internal

import kotlin.math.exp
import kotlin.random.Random

/**
 * Greedy + temperature/top-p/top-k sampler for LiteRT logits. Pure Kotlin,
 * no LiteRT or HuggingFace tokenizer dependency — purely numerical.
 *
 * Mirrors `CoreMLSampler.swift` (iOS) 1:1; algorithm comments are kept in
 * lockstep with the iOS implementation so future fixes apply uniformly.
 *
 * @param temperature 0.0 = pure argmax (deterministic). >0.0 enables
 *                     temperature scaling.
 * @param topP         Nucleus-sampling cutoff. 1.0 = disabled (consider all
 *                     tokens). 0.0 < topP < 1.0 = keep tokens whose
 *                     cumulative probability covers `topP`.
 * @param topK         0 = disabled. >0 = keep only the K highest-probability
 *                     tokens before sampling.
 * @param random       Source of randomness. Test code seeds for determinism.
 */
internal class LiteRTSampler(
    private val temperature: Float,
    private val topP: Float,
    private val topK: Int,
    private val random: Random = Random.Default,
) {
    fun sample(logits: FloatArray): Int {
        // Fast path: temperature == 0 -> pure argmax. Avoids softmax allocation.
        if (temperature <= 0f) return argmax(logits)

        // Apply temperature: divide each logit by T, then softmax over the
        // result. Larger T flattens the distribution, smaller T sharpens.
        val scaled = FloatArray(logits.size) { logits[it] / temperature }
        val probs = softmax(scaled)

        // Build (idx, prob) pairs, sorted descending by prob. Allocates an
        // index array proportional to vocab size — typically 32k-256k.
        val sortedIdxByProbDesc = (probs.indices)
            .sortedByDescending { probs[it] }

        // top-k truncation: keep only the first K entries.
        val afterTopK = if (topK > 0 && topK < sortedIdxByProbDesc.size) {
            sortedIdxByProbDesc.subList(0, topK)
        } else {
            sortedIdxByProbDesc
        }

        // top-p (nucleus) truncation: keep prefix of indices whose cumulative
        // probability covers `topP`. Always keep at least one token.
        val afterTopP = if (topP > 0f && topP < 1f) {
            val kept = mutableListOf<Int>()
            var cum = 0f
            for (idx in afterTopK) {
                kept.add(idx)
                cum += probs[idx]
                if (cum >= topP) break
            }
            kept
        } else {
            afterTopK
        }

        // Renormalize the kept distribution and sample multinomially.
        val keptProbs = afterTopP.map { probs[it] }
        val total = keptProbs.sum()
        val r = random.nextFloat() * total
        var acc = 0f
        for ((i, p) in keptProbs.withIndex()) {
            acc += p
            if (r <= acc) return afterTopP[i]
        }
        // Numerical fall-through: return last kept index.
        return afterTopP.last()
    }

    private fun argmax(arr: FloatArray): Int {
        var best = 0
        var bestVal = arr[0]
        for (i in 1 until arr.size) {
            if (arr[i] > bestVal) {
                bestVal = arr[i]
                best = i
            }
        }
        return best
    }

    /**
     * Numerically-stable softmax: subtract max, exp, normalize. Avoids
     * overflow on large logits. Returns a new FloatArray of the same size.
     */
    private fun softmax(arr: FloatArray): FloatArray {
        var max = arr[0]
        for (i in 1 until arr.size) if (arr[i] > max) max = arr[i]
        var sum = 0f
        val out = FloatArray(arr.size) { i ->
            val e = exp((arr[i] - max).toDouble()).toFloat()
            sum += e
            e
        }
        for (i in out.indices) out[i] /= sum
        return out
    }
}
