package co.deepvoiceai.bridge.litert.core.Internal

import co.deepvoiceai.bridge.litert.core.LiteRTBackendError
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File

/**
 * Pure-Kotlin BPE tokenizer that loads HuggingFace's standard
 * `tokenizer.json` schema. No JNI, no native library — works on every
 * Android ABI without surprise UnsatisfiedLinkErrors.
 *
 * Why a custom parser instead of an off-the-shelf artifact?
 *  - `com.github.huggingface:tokenizers-android` (JitPack) does not exist —
 *    the URL 401s. The plan's original guess was wrong.
 *  - `ai.djl.huggingface:tokenizers:0.36.0` (Maven Central) is JVM-only:
 *    DJL ships `libtokenizers.so` for x86_64 + aarch64-linux-gnu + macOS +
 *    Windows but NOT for Android (`*-linux-android`). Pulling DJL would
 *    crash the first encode() with UnsatisfiedLinkError on every Android
 *    target ABI.
 *  - HF's official Rust crate has no Android JNI wrapper on Maven.
 *
 * What's supported:
 *  - BPE merges (byte-pair encoding) — the standard Llama-3 / Gemma-2
 *    tokenizer.json shape: `model.type == "BPE"`, `model.vocab` as
 *    {token: id}, `model.merges` as space-separated `"A B"` pairs OR
 *    array-of-pair tuples (HF v0.21+ format).
 *  - Special / added tokens via `added_tokens` array (each entry is
 *    `{ id, content, special }`).
 *  - GPT-2 byte-level encoding pre-tokenizer (the standard Llama-3 case):
 *    every input byte mapped through GPT-2's printable byte permutation
 *    so the BPE step never has to handle unicode-class boundaries.
 *  - decode() reverses the byte-level mapping and concatenates pieces.
 *
 * What's NOT supported (call sites must avoid these models):
 *  - SentencePiece / Unigram tokenizers (`model.type == "Unigram"`) — Gemma
 *    uses these; for Gemma checkpoints the consumer should use the
 *    mediapipe backend instead which uses LiteRT-LM's bundled SentencePiece.
 *  - Jinja chat templates from `tokenizer_config.json`. The handler layer
 *    formats messages with a hard-coded Llama-3-style template
 *    (`<|begin_of_text|><|start_header_id|>{role}<|end_header_id|>\n\n{content}<|eot_id|>`)
 *    which works for Llama-3 family checkpoints; non-Llama checkpoints
 *    require the consumer to pre-render the prompt themselves.
 *  - Pre-tokenizer types other than ByteLevel (Whitespace, Sequence, etc.).
 *
 * If the loader encounters an unsupported tokenizer.json shape it throws
 * [LiteRTBackendError.TokenizerLoadFailed] with a precise reason so the
 * caller can fall back to a different backend.
 *
 * Mirrors the role of `CoreMLTokenizer.swift` (iOS) without the
 * swift-transformers dependency — there's no equivalent maintained library
 * on Android.
 */
internal class HFTokenizerJson private constructor(
    private val vocab: Map<String, Int>,
    private val idToToken: Map<Int, String>,
    private val mergeRanks: Map<Pair<String, String>, Int>,
    private val specialTokens: Set<String>,
    private val byteToUnicode: Map<Int, Char>,
    private val unicodeToByte: Map<Char, Int>,
    val bosTokenId: Int?,
    val eosTokenId: Int,
    val padTokenId: Int?,
) {

    /**
     * Encode a UTF-8 string to a token-id list using BPE.
     *
     * Pipeline: UTF-8 bytes -> GPT-2 byte→unicode permutation -> BPE merges
     * -> vocab lookup. Special tokens in the input string are matched
     * verbatim before BPE runs (so `<|eot_id|>` resolves to a single id
     * rather than being split into pieces).
     */
    fun encode(text: String): List<Int> {
        if (text.isEmpty()) return emptyList()
        val out = mutableListOf<Int>()
        // Greedy special-token splitter: for each occurrence of a known
        // special token, emit it as a single id; BPE the gap before it.
        var cursor = 0
        while (cursor < text.length) {
            val match = findNextSpecial(text, cursor)
            if (match == null) {
                val tail = text.substring(cursor)
                if (tail.isNotEmpty()) out.addAll(encodeBpe(tail))
                break
            }
            // BPE the plain segment before the special token, then emit
            // the special token id, then advance past it.
            if (match.start > cursor) {
                out.addAll(encodeBpe(text.substring(cursor, match.start)))
            }
            out.add(vocab.getValue(match.token))
            cursor = match.start + match.token.length
        }
        return out
    }

    private data class SpecialMatch(val token: String, val start: Int)

    /** Earliest-occurrence special token at or after [from]. Null if none. */
    private fun findNextSpecial(text: String, from: Int): SpecialMatch? {
        var best: SpecialMatch? = null
        for (special in specialTokens) {
            val idx = text.indexOf(special, from)
            if (idx < 0) continue
            if (best == null || idx < best.start) {
                best = SpecialMatch(special, idx)
            }
        }
        return best
    }

    private fun encodeBpe(text: String): List<Int> {
        // GPT-2 byte-level: every UTF-8 byte mapped to a single unicode
        // character via the byteToUnicode permutation, then BPE operates
        // over the resulting string as a single "word" (HF tokenizer.json
        // ByteLevel pre-tokenizer's default is to NOT split on whitespace
        // for Llama-3 — every word boundary is preserved as a Ġ-prefixed
        // piece during merges).
        val bytes = text.toByteArray(Charsets.UTF_8)
        val mapped = StringBuilder(bytes.size)
        for (b in bytes) {
            val unsigned = b.toInt() and 0xFF
            mapped.append(byteToUnicode.getValue(unsigned))
        }
        return bpe(mapped.toString())
    }

    /**
     * Apply BPE merges greedily to a single byte-level-encoded "word".
     *
     * Standard HF BPE algorithm:
     *  1. Split the word into individual chars.
     *  2. Find the pair with the lowest merge-rank among adjacent pairs.
     *  3. Merge that pair everywhere it occurs in the symbol list.
     *  4. Repeat until no more merges apply.
     *  5. Look up each resulting symbol in the vocab.
     */
    private fun bpe(word: String): List<Int> {
        if (word.isEmpty()) return emptyList()
        val symbols = word.map { it.toString() }.toMutableList()
        if (symbols.size == 1) {
            return listOf(vocab[symbols[0]] ?: vocab.getValue("<unk>"))
        }

        while (symbols.size >= 2) {
            // Find lowest-rank adjacent pair.
            var bestRank = Int.MAX_VALUE
            var bestIdx = -1
            for (i in 0 until symbols.size - 1) {
                val rank = mergeRanks[symbols[i] to symbols[i + 1]] ?: continue
                if (rank < bestRank) {
                    bestRank = rank
                    bestIdx = i
                }
            }
            if (bestIdx < 0) break
            // Merge every occurrence of the best pair, left-to-right.
            val left = symbols[bestIdx]
            val right = symbols[bestIdx + 1]
            val merged = left + right
            var r = 0
            val rebuilt = ArrayList<String>(symbols.size)
            while (r < symbols.size) {
                if (r < symbols.size - 1 && symbols[r] == left && symbols[r + 1] == right) {
                    rebuilt.add(merged)
                    r += 2
                } else {
                    rebuilt.add(symbols[r])
                    r += 1
                }
            }
            symbols.clear()
            symbols.addAll(rebuilt)
        }

        return symbols.map { sym ->
            vocab[sym] ?: vocab["<unk>"] ?: error("token '$sym' not in vocab and no <unk> fallback")
        }
    }

    /**
     * Decode a list of token ids back to a UTF-8 string. Reverses the
     * byte-level mapping. Special tokens are skipped if [skipSpecialTokens]
     * is true (the default for chat output).
     */
    fun decode(tokens: List<Int>, skipSpecialTokens: Boolean = true): String {
        val pieces = StringBuilder()
        for (id in tokens) {
            val tok = idToToken[id] ?: continue
            if (skipSpecialTokens && tok in specialTokens) continue
            pieces.append(tok)
        }
        // Reverse the byte-level mapping: every char in `pieces` was the
        // image of one input byte. Map each char back to its byte value
        // and decode the resulting byte sequence as UTF-8.
        val out = ByteArray(pieces.length)
        var n = 0
        for (i in pieces.indices) {
            val byteVal = unicodeToByte[pieces[i]]
            // Tokens added by `added_tokens` (e.g. chat-template control
            // tokens) live OUTSIDE the byte-level alphabet — their chars
            // are not in unicodeToByte. Skip them (or emit '?' if you want
            // a visible artefact). For chat output, skipping is correct.
            if (byteVal != null) {
                out[n] = byteVal.toByte()
                n += 1
            }
        }
        return String(out, 0, n, Charsets.UTF_8)
    }

    fun decode(token: Int): String = decode(listOf(token), skipSpecialTokens = true)

    companion object {
        private val parser = Json { ignoreUnknownKeys = true }

        /**
         * Load a tokenizer.json from disk. Throws
         * [LiteRTBackendError.TokenizerLoadFailed] on any parse / structure
         * failure with a precise reason.
         */
        @Throws(LiteRTBackendError.TokenizerLoadFailed::class)
        fun load(tokenizerJsonPath: String, eosTokenIdOverride: Int? = null): HFTokenizerJson {
            val file = File(tokenizerJsonPath)
            if (!file.isFile) {
                throw LiteRTBackendError.TokenizerLoadFailed(
                    "tokenizer.json not found at $tokenizerJsonPath",
                )
            }
            val root = try {
                parser.parseToJsonElement(file.readText()).jsonObject
            } catch (t: Throwable) {
                throw LiteRTBackendError.TokenizerLoadFailed("failed to parse tokenizer.json: ${t.message}")
            }

            val model = root["model"] as? JsonObject
                ?: throw LiteRTBackendError.TokenizerLoadFailed("tokenizer.json: missing 'model' object")
            val type = (model["type"] as? JsonPrimitive)?.contentOrNull
            if (type != null && type != "BPE") {
                throw LiteRTBackendError.TokenizerLoadFailed(
                    "tokenizer.json: model.type='$type' is not supported (only BPE). Use the mediapipe backend for SentencePiece/Unigram models.",
                )
            }

            val vocabRaw = model["vocab"] as? JsonObject
                ?: throw LiteRTBackendError.TokenizerLoadFailed("tokenizer.json: missing 'model.vocab'")
            val vocab = HashMap<String, Int>(vocabRaw.size)
            val idToToken = HashMap<Int, String>(vocabRaw.size)
            for ((tok, idEl) in vocabRaw) {
                val id = (idEl as? JsonPrimitive)?.intOrNull
                    ?: throw LiteRTBackendError.TokenizerLoadFailed("tokenizer.json: vocab entry '$tok' is not an int")
                vocab[tok] = id
                idToToken[id] = tok
            }

            val mergesRaw = model["merges"] as? JsonArray
                ?: throw LiteRTBackendError.TokenizerLoadFailed("tokenizer.json: missing 'model.merges'")
            val mergeRanks = HashMap<Pair<String, String>, Int>(mergesRaw.size)
            for ((rank, mEl) in mergesRaw.withIndex()) {
                val pair = parseMergeEntry(mEl)
                    ?: throw LiteRTBackendError.TokenizerLoadFailed(
                        "tokenizer.json: merges[$rank] is not a 'A B' string or [A,B] pair",
                    )
                mergeRanks[pair] = rank
            }

            // Special / added tokens. Each entry shape: { id, content, special, ... }.
            // We treat anything with `special: true` (or anything in this list,
            // since added_tokens are by convention always specials in modern HF
            // tokenizer.json files) as a special token: matched verbatim by
            // encode(), skipped by decode() when skipSpecialTokens=true.
            val specialTokens = mutableSetOf<String>()
            (root["added_tokens"] as? JsonArray)?.forEach { entry ->
                val obj = entry as? JsonObject ?: return@forEach
                val content = (obj["content"] as? JsonPrimitive)?.contentOrNull ?: return@forEach
                val id = (obj["id"] as? JsonPrimitive)?.intOrNull
                if (id != null) {
                    vocab[content] = id
                    idToToken[id] = content
                }
                val isSpecial = (obj["special"] as? JsonPrimitive)?.booleanOrNull ?: true
                if (isSpecial) specialTokens.add(content)
            }

            // Discover BOS / EOS / PAD ids from `added_tokens` first, then
            // from the standard names. The caller can override EOS via opts.
            val bosTokenId = vocab["<|begin_of_text|>"] ?: vocab["<s>"] ?: vocab["<bos>"]
            val discoveredEos = vocab["<|eot_id|>"]
                ?: vocab["<|end_of_text|>"]
                ?: vocab["</s>"]
                ?: vocab["<eos>"]
            val eosTokenId = eosTokenIdOverride ?: discoveredEos
                ?: throw LiteRTBackendError.TokenizerLoadFailed(
                    "tokenizer.json: no EOS-like token in added_tokens (looked for <|eot_id|>, <|end_of_text|>, </s>, <eos>) — pass eosTokenId in start opts to override",
                )
            val padTokenId = vocab["<pad>"] ?: vocab["<|pad|>"]

            val (b2u, u2b) = buildByteLevelMap()

            return HFTokenizerJson(
                vocab = vocab,
                idToToken = idToToken,
                mergeRanks = mergeRanks,
                specialTokens = specialTokens,
                byteToUnicode = b2u,
                unicodeToByte = u2b,
                bosTokenId = bosTokenId,
                eosTokenId = eosTokenId,
                padTokenId = padTokenId,
            )
        }

        /**
         * Parse one entry of tokenizer.json's `model.merges` array. Two
         * shapes are seen in the wild:
         *  - String: "A B" (older HF, Llama-2-style). Split on first space.
         *  - Array of two strings: ["A", "B"] (HF v0.21+ default).
         */
        private fun parseMergeEntry(el: kotlinx.serialization.json.JsonElement): Pair<String, String>? {
            return when (el) {
                is JsonPrimitive -> {
                    val s = el.contentOrNull ?: return null
                    val sp = s.indexOf(' ')
                    if (sp < 0) return null
                    s.substring(0, sp) to s.substring(sp + 1)
                }
                is JsonArray -> {
                    if (el.size != 2) return null
                    val a = (el[0] as? JsonPrimitive)?.contentOrNull ?: return null
                    val b = (el[1] as? JsonPrimitive)?.contentOrNull ?: return null
                    a to b
                }
                else -> null
            }
        }

        /**
         * Construct GPT-2's reversible byte→unicode permutation. Maps each
         * of the 256 byte values to a printable unicode codepoint:
         *  - Bytes that are already printable ASCII (33..126), Latin-1
         *    supplement printable (161..172, 174..255) map to themselves.
         *  - All other bytes (0..32, 127..160, 173) map to the Latin-1
         *    Supplement / Latin-Extended-A range starting at 256, in order.
         *
         * Reference: HuggingFace tokenizers' ByteLevel `bytes_to_unicode()`
         * Python helper. The output map is identical between HF Python,
         * tokenizers Rust, and this Kotlin port.
         */
        private fun buildByteLevelMap(): Pair<Map<Int, Char>, Map<Char, Int>> {
            val printable = (33..126) + (161..172) + (174..255)
            val bs = printable.toMutableList()
            val cs = printable.map { it }.toMutableList()
            var n = 0
            for (b in 0..255) {
                if (b !in printable) {
                    bs.add(b)
                    cs.add(256 + n)
                    n += 1
                }
            }
            val byteToChar = HashMap<Int, Char>(256)
            val charToByte = HashMap<Char, Int>(256)
            for (i in bs.indices) {
                val ch = cs[i].toChar()
                byteToChar[bs[i]] = ch
                charToByte[ch] = bs[i]
            }
            return byteToChar to charToByte
        }
    }
}
