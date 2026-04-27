package co.deepvoiceai.bridge.litert.core.Internal

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/**
 * Unit tests for [LiteRTGenerator]'s decode-loop control flow, using a
 * fake [LiteRTEngineApi] that returns canned logits so we can verify:
 *
 *  - Tokens come out in the order the engine's logits dictate (greedy).
 *  - EOS terminates the loop early.
 *  - maxNewTokens caps the loop even when EOS is never produced.
 *  - kvCachePosition is incremented monotonically across runStep calls.
 *
 * Tokenizer: a tiny stub that maps the prompt to a fixed token list and
 * round-trips token ids through a vocab built off raw chars. This avoids
 * loading a real tokenizer.json from disk in a unit test.
 */
class LiteRTGeneratorMockTest {

    /** Records every (token, kvPos) pair the generator feeds. */
    private class CallLog {
        val calls = mutableListOf<Pair<Int, Int>>()
    }

    /**
     * Fake engine: returns canned logits whose argmax is the *next*
     * entry in [predictionsAfterPrefill] starting from the last prefill
     * call. Earlier prefill calls return zero-vector logits — those
     * predictions are immediately overwritten by the next prefill step,
     * so their values are irrelevant.
     *
     * @param promptLen number of prefill calls the generator will make
     *                   (= prompt token count). The fake counts down
     *                   `promptLen` calls before it starts emitting
     *                   meaningful argmax targets from
     *                   [predictionsAfterPrefill][0].
     */
    private class FakeEngine(
        override val vocabSize: Int,
        override val eosTokenId: Int,
        private val promptLen: Int,
        private val predictionsAfterPrefill: List<Int>,
        private val log: CallLog,
    ) : LiteRTEngineApi {
        private var callIdx = 0

        override fun runStep(token: Int, kvCachePosition: Int): FloatArray {
            log.calls.add(token to kvCachePosition)
            val logits = FloatArray(vocabSize) { -10f }
            // First (promptLen - 1) calls are early-prefill; their logits
            // are immediately overwritten by the next prefill call so we
            // emit no preference. Call (promptLen - 1) is the LAST prefill
            // — its argmax is the FIRST sampled token. From there on,
            // each runStep is a decode-feed and its argmax is the next
            // sampled token.
            val predictionIdx = callIdx - (promptLen - 1)
            callIdx += 1
            if (predictionIdx < 0) return logits
            val target = if (predictionIdx < predictionsAfterPrefill.size) {
                predictionsAfterPrefill[predictionIdx]
            } else {
                eosTokenId
            }
            logits[target] = 100f // dominant
            return logits
        }

        override fun close() {}
    }

    /**
     * Build a tokenizer over a tiny ASCII alphabet so the generator's
     * encode + decode round-trips deterministically. We use the
     * pure-Kotlin BPE loader's output via a synthetic JSON; that's
     * heavier than needed here, so we provide a hand-rolled stub
     * instead by writing a tokenizer.json to a temp file.
     *
     * Since the production code only depends on encode/decode, a far
     * simpler approach is to build the tokenizer through a custom
     * factory bypassing the JSON loader. We do that via reflection on
     * the private constructor — but that's brittle. Instead, write a
     * minimal valid tokenizer.json and load it normally.
     */
    private fun buildTinyTokenizer(eosId: Int = 99): HFTokenizerJson {
        // Minimal tokenizer.json with BPE model and added_tokens for EOS.
        // Vocab covers single-byte chars 'a'..'e' (which after byte-level
        // mapping become themselves since 'a'..'e' are in the printable
        // ASCII range 33..126) plus the EOS special.
        val json = """
        {
          "model": {
            "type": "BPE",
            "vocab": { "a": 0, "b": 1, "c": 2, "d": 3, "e": 4 },
            "merges": []
          },
          "added_tokens": [
            { "id": $eosId, "content": "<|eot_id|>", "special": true }
          ]
        }
        """.trimIndent()
        val tmp = java.io.File.createTempFile("litert-test-tokenizer", ".json")
        tmp.deleteOnExit()
        tmp.writeText(json)
        return HFTokenizerJson.load(tmp.absolutePath)
    }

    @Test
    fun `generator emits scripted tokens in order`() = runBlocking {
        // Prompt "abc" tokenizes to [0, 1, 2] (promptLen=3). After the
        // last prefill step the engine predicts 3 ('d'), then 4 ('e'),
        // then 99 (EOS). Decoded output is "de".
        val log = CallLog()
        val tokenizer = buildTinyTokenizer(eosId = 99)
        val engine = FakeEngine(
            vocabSize = 100,
            eosTokenId = 99,
            promptLen = 3,
            predictionsAfterPrefill = listOf(3, 4, 99),
            log = log,
        )
        val sampler = LiteRTSampler(temperature = 0f, topP = 1f, topK = 0, random = Random(42))
        val gen = LiteRTGenerator(engine, tokenizer, sampler, maxNewTokens = 16)

        val output = gen.generate("abc")
        assertEquals("de", output)
    }

    @Test
    fun `generator stops on EOS`() = runBlocking {
        // promptLen=1: prompt "a" -> [0] -> single prefill call. Its
        // argmax is EOS, so the decode loop terminates before producing
        // any token.
        val log = CallLog()
        val tokenizer = buildTinyTokenizer(eosId = 99)
        val engine = FakeEngine(
            vocabSize = 100,
            eosTokenId = 99,
            promptLen = 1,
            predictionsAfterPrefill = listOf(99),
            log = log,
        )
        val sampler = LiteRTSampler(temperature = 0f, topP = 1f, topK = 0, random = Random(42))
        val gen = LiteRTGenerator(engine, tokenizer, sampler, maxNewTokens = 99)

        val output = gen.generate("a") // tokenizes to [0]
        assertEquals("", output)
        // Exactly one runStep call (the prefill); first sample produced
        // EOS so the decode loop never invoked the engine again.
        assertEquals(1, log.calls.size)
        assertEquals(0 to 0, log.calls[0])
    }

    @Test
    fun `generator caps at maxNewTokens when EOS never emitted`() = runBlocking {
        // 100 'd's in a row, never EOS. maxNewTokens=5 caps the loop.
        val log = CallLog()
        val tokenizer = buildTinyTokenizer(eosId = 99)
        val script = List(100) { 3 }
        val engine = FakeEngine(
            vocabSize = 100,
            eosTokenId = 99,
            promptLen = 3,
            predictionsAfterPrefill = script,
            log = log,
        )
        val sampler = LiteRTSampler(temperature = 0f, topP = 1f, topK = 0, random = Random(42))
        val gen = LiteRTGenerator(engine, tokenizer, sampler, maxNewTokens = 5)

        val output = gen.generate("abc") // tokenizes to [0,1,2]
        assertEquals("ddddd", output)
    }

    @Test
    fun `kvCachePosition increments monotonically across calls`() = runBlocking {
        val log = CallLog()
        val tokenizer = buildTinyTokenizer(eosId = 99)
        val engine = FakeEngine(
            vocabSize = 100,
            eosTokenId = 99,
            promptLen = 3,
            predictionsAfterPrefill = listOf(3, 4, 99),
            log = log,
        )
        val sampler = LiteRTSampler(temperature = 0f, topP = 1f, topK = 0, random = Random(42))
        val gen = LiteRTGenerator(engine, tokenizer, sampler, maxNewTokens = 16)

        gen.generate("abc")

        // Expected calls (token, kvPos):
        //  0: (0, 0) prefill[0] — early-prefill, argmax irrelevant
        //  1: (1, 1) prefill[1] — early-prefill, argmax irrelevant
        //  2: (2, 2) prefill[2] — last prefill -> sample produces 3
        //  3: (3, 3) decode-feed -> sample produces 4
        //  4: (4, 4) decode-feed -> sample produces 99 -> EOS halts
        assertEquals(5, log.calls.size)
        assertEquals(0 to 0, log.calls[0])
        assertEquals(1 to 1, log.calls[1])
        assertEquals(2 to 2, log.calls[2])
        assertEquals(3 to 3, log.calls[3])
        assertEquals(4 to 4, log.calls[4])
        for (i in log.calls.indices) {
            assertEquals(i, log.calls[i].second)
        }
    }

    @Test
    fun `empty prompt throws GenerationFailed`() = runBlocking {
        val log = CallLog()
        val tokenizer = buildTinyTokenizer(eosId = 99)
        val engine = FakeEngine(
            vocabSize = 100,
            eosTokenId = 99,
            promptLen = 0,
            predictionsAfterPrefill = listOf(3),
            log = log,
        )
        val sampler = LiteRTSampler(temperature = 0f, topP = 1f, topK = 0, random = Random(42))
        val gen = LiteRTGenerator(engine, tokenizer, sampler, maxNewTokens = 4)

        try {
            gen.generate("")
            org.junit.Assert.fail("expected GenerationFailed for empty prompt")
        } catch (e: co.deepvoiceai.bridge.litert.core.LiteRTBackendError.GenerationFailed) {
            assertTrue(e.message!!.contains("empty"))
        }
        // Engine never invoked — the generator validates BEFORE the first
        // runStep call.
        assertEquals(0, log.calls.size)
    }
}
