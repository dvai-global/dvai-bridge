package co.deepvoiceai.bridge.litert.core.Internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/**
 * Unit tests for [LiteRTSampler]. Pure-Kotlin sampler — no Robolectric or
 * Android runtime needed, plain JUnit 4.
 *
 * The sampler mirrors `CoreMLSampler.swift` (iOS); these tests intentionally
 * mirror what would be the iOS test cases so a behavioural divergence
 * surfaces in both suites.
 */
class LiteRTSamplerTest {

    /**
     * temperature == 0 must take the pure-argmax path regardless of topP /
     * topK. This is the deterministic chat / function-calling default.
     */
    @Test
    fun `temperature zero is argmax`() {
        val sampler = LiteRTSampler(temperature = 0f, topP = 1f, topK = 0, random = Random(42))
        val logits = floatArrayOf(0.1f, 5.0f, -1.0f, 4.99f)
        // Argmax = index 1 (5.0). Run repeatedly to confirm zero variance.
        repeat(8) {
            assertEquals(1, sampler.sample(logits))
        }
    }

    /**
     * topK = 1 must collapse to argmax even when temperature > 0 — the
     * post-softmax distribution has a single non-zero entry, so multinomial
     * sampling can only return the argmax index.
     */
    @Test
    fun `topK one with positive temperature is deterministic argmax`() {
        val sampler = LiteRTSampler(temperature = 1.0f, topP = 1f, topK = 1, random = Random(42))
        val logits = floatArrayOf(-2.0f, 0.5f, 3.7f, 1.2f)
        // Argmax = index 2.
        repeat(16) {
            assertEquals(2, sampler.sample(logits))
        }
    }

    /**
     * topP truncation: with cumulative-prob cutoff = 0.5 and a sharply
     * peaked distribution (one logit dominates softmax > 0.5), only the
     * argmax index can be returned.
     */
    @Test
    fun `topP truncation keeps cumulative probability cutoff`() {
        val sampler = LiteRTSampler(temperature = 1.0f, topP = 0.5f, topK = 0, random = Random(42))
        // logits[3] = 10 dominates softmax (>>99% mass) — top-p=0.5 keeps
        // exactly one index, so sampling collapses to argmax = 3.
        val logits = floatArrayOf(0f, 0f, 0f, 10f, 0f)
        repeat(16) {
            assertEquals(3, sampler.sample(logits))
        }
    }

    /**
     * Without truncation and a flat distribution, different RNG seeds
     * must select different indices — confirms the multinomial path runs
     * (regression test against an accidental shortcut to argmax).
     */
    @Test
    fun `flat distribution with different seeds yields varied samples`() {
        val flat = FloatArray(8) { 0f } // softmax = uniform 1/8
        val s1 = LiteRTSampler(temperature = 1f, topP = 1f, topK = 0, random = Random(1))
        val s2 = LiteRTSampler(temperature = 1f, topP = 1f, topK = 0, random = Random(99))
        // Two seeds drawing from a uniform distribution over 8 buckets are
        // overwhelmingly likely to disagree on at least one of 5 draws —
        // probability of all 5 matches is (1/8)^5 ~ 3e-5.
        var anyDifferent = false
        repeat(5) {
            if (s1.sample(flat) != s2.sample(flat)) {
                anyDifferent = true
            }
        }
        assertTrue("expected varied samples across different seeds", anyDifferent)
    }

    /**
     * Determinism: same seed + same logits must produce the same sequence
     * of samples. Catches accidental statics or non-deterministic sort.
     */
    @Test
    fun `same seed produces identical sequence`() {
        val logits = floatArrayOf(1f, 2f, 3f, 4f, 5f)
        val s1 = LiteRTSampler(temperature = 0.7f, topP = 0.9f, topK = 4, random = Random(42))
        val s2 = LiteRTSampler(temperature = 0.7f, topP = 0.9f, topK = 4, random = Random(42))
        for (i in 0 until 32) {
            val a = s1.sample(logits)
            val b = s2.sample(logits)
            assertEquals("sample $i", a, b)
        }
    }

    /**
     * Single-element logits: every sampler config must return index 0
     * since there's nothing else to pick. Edge case at the start of the
     * vocab loop.
     */
    @Test
    fun `single element logits returns index zero`() {
        val logits = floatArrayOf(2.0f)
        val configs = listOf(
            LiteRTSampler(temperature = 0f, topP = 1f, topK = 0, random = Random(42)),
            LiteRTSampler(temperature = 1f, topP = 1f, topK = 0, random = Random(42)),
            LiteRTSampler(temperature = 1f, topP = 0.5f, topK = 1, random = Random(42)),
        )
        for (s in configs) {
            assertEquals(0, s.sample(logits))
        }
    }

    /**
     * Soft sanity: with a non-degenerate distribution and temperature > 0,
     * a sufficiently large sample should NOT always equal the argmax.
     * Ensures the sampler isn't silently short-circuiting to argmax.
     */
    @Test
    fun `non greedy sampling is not always argmax`() {
        val logits = floatArrayOf(1f, 1.05f, 1f, 1f) // near-uniform with slight tilt
        val sampler = LiteRTSampler(temperature = 1f, topP = 1f, topK = 0, random = Random(7))
        var nonArgmax = 0
        for (i in 0 until 50) {
            val s = sampler.sample(logits)
            if (s != 1) nonArgmax += 1 // 1 is the argmax
        }
        assertNotEquals("expected at least some non-argmax draws", 0, nonArgmax)
    }
}
