package co.deepvoiceai.bridge.llama.core

import java.util.Base64

/**
 * The canonical media-marker token mtmd uses for image/audio splice points.
 * Mirrors `mtmd_default_marker()` from `tools/mtmd/mtmd.h`.
 */
const val MTMD_MEDIA_MARKER: String = "<__media__>"

/** One rendered chat message ready for `bridge.applyChatTemplate(...)`. */
data class LlamaTranslatedMessage(
    val role: String,
    val content: String,
)

/**
 * Output of [ContentPartsTranslator.translate] — the raw inputs the llama.cpp
 * handler will hand to `bridge.applyChatTemplate(...)` and
 * `bridge.completeMultimodalPrompt(...)`.
 */
data class LlamaPromptInput(
    /** Per-message rendered content with media replaced by `<__media__>` markers. */
    val messagesWithMarkers: List<LlamaTranslatedMessage>,
    /**
     * All media bytes (images + decoded audio) in declaration order across
     * all messages, matching the order the markers appear. mtmd's tokenize
     * matches markers to bitmaps by position; auto-detection of image vs
     * audio happens via magic bytes inside `mtmd_helper_bitmap_init_from_buf`.
     */
    val media: List<ByteArray>,
    /** Legacy: concatenation of all `text` parts for diagnostics. */
    val prompt: String,
)

/**
 * Errors raised by [ContentPartsTranslator.translate]. The HTTP-status mapping
 * (per spec §8.5) is owned by the handler layer; the translator just throws
 * the typed subclass.
 */
sealed class TranslatorError(msg: String) : Exception(msg) {
    /** 400 — `Request includes an image but no mmproj was loaded. Set nativeMmprojPath when starting.` */
    class NoMmprojForImage : TranslatorError(
        "Request includes an image but no mmproj was loaded. Set nativeMmprojPath when starting.",
    )

    /** 400 — `Loaded model has no native audio encoder. Use a multimodal model like Gemma 4 or Phi-4 Multimodal.` */
    class AudioWithoutAudioEncoder : TranslatorError(
        "Loaded model has no native audio encoder. " +
            "Use a multimodal model like Gemma 4 or Phi-4 Multimodal.",
    )

    /** 400 — `Unsupported audio format: <fmt>. Supported on this platform: <list>.` */
    class UnsupportedAudioFormat(
        val format: String,
        val supported: List<String>,
    ) : TranslatorError(
        "Unsupported audio format: $format. Supported on this platform: ${supported.joinToString(", ")}.",
    )

    /** 400 — `Audio decode failed: <reason>`. */
    class AudioDecodeFailed(reason: String) : TranslatorError("Audio decode failed: $reason")

    /** 502 — `Failed to fetch image: <reason>`. */
    class ImageFetchFailed(reason: String) : TranslatorError("Failed to fetch image: $reason")

    /** 400 — `<reason>`. Used for shape errors (missing role, unknown part type, etc.). */
    class MalformedRequest(reason: String) : TranslatorError(reason)
}

/**
 * Walks an OpenAI-style `messages` list and produces a [LlamaPromptInput]
 * bundle: per-message content with media parts replaced by `<__media__>`
 * markers, paired with a flat list of media bytes in declaration order.
 *
 * mtmd does its own format detection (via miniaudio) inside
 * `mtmd_helper_bitmap_init_from_buf` by inspecting magic bytes, so the
 * translator hands it the raw base64-decoded audio bytes — still in their
 * original WAV/MP3/FLAC envelope — rather than headerless PCM samples.
 * `mtmd_helper_bitmap_init_from_buf` only recognizes WAV/MP3/FLAC and would
 * fail silently on raw PCM.
 *
 * Audio data contract: `input_audio.data` must be standard base64 (RFC 4648
 * §4); URL-safe base64 (`-` / `_` chars) is rejected. This matches OpenAI's
 * documented input format.
 *
 * Spec reference: §8.1 (content-part shape), §8.2 (image translation), §8.3
 * (audio translation), §8.5 (error mapping).
 *
 * The [audioDecoder] parameter is currently unused on the production path —
 * mtmd handles audio decoding internally — but is retained for backward
 * compatibility with existing tests and as a possible future fallback for
 * formats mtmd cannot decode itself.
 */
class ContentPartsTranslator(
    private val mmprojLoaded: Boolean,
    private val modelHasAudioEncoder: Boolean,
    private val imageDecoder: (String) -> ByteArray = { url -> ImageDecoder.resolve(url) },
    @Suppress("unused")
    private val audioDecoder: (ByteArray, AudioFormat) -> ByteArray = AudioDecoder::decode,
) {
    suspend fun translate(messages: List<Map<String, Any?>>): LlamaPromptInput {
        val translated = mutableListOf<LlamaTranslatedMessage>()
        val media = mutableListOf<ByteArray>()
        val promptParts = mutableListOf<String>()

        for ((msgIdx, msg) in messages.withIndex()) {
            val role = msg["role"] as? String
                ?: throw TranslatorError.MalformedRequest("messages[$msgIdx] missing string 'role'")
            val rendered = mutableListOf<String>()

            when (val content = msg["content"]) {
                is String -> {
                    promptParts += content
                    rendered += content
                }
                is List<*> -> {
                    for ((partIdx, rawPart) in content.withIndex()) {
                        val path = "messages[$msgIdx].content[$partIdx]"
                        @Suppress("UNCHECKED_CAST")
                        val part = rawPart as? Map<String, Any?>
                            ?: throw TranslatorError.MalformedRequest("$path is not an object")
                        val type = part["type"] as? String
                            ?: throw TranslatorError.MalformedRequest("$path missing string 'type'")
                        when (type) {
                            "text" -> {
                                val text = part["text"] as? String
                                    ?: throw TranslatorError.MalformedRequest("$path text part missing string 'text'")
                                promptParts += text
                                rendered += text
                            }
                            "image_url" -> {
                                if (!mmprojLoaded) throw TranslatorError.NoMmprojForImage()
                                @Suppress("UNCHECKED_CAST")
                                val imgObj = part["image_url"] as? Map<String, Any?>
                                    ?: throw TranslatorError.MalformedRequest("$path image_url part missing image_url object")
                                val url = imgObj["url"] as? String
                                    ?: throw TranslatorError.MalformedRequest("$path image_url part missing image_url.url")
                                val bytes = try {
                                    imageDecoder(url)
                                } catch (e: Exception) {
                                    throw TranslatorError.ImageFetchFailed(e.message ?: e::class.java.simpleName)
                                }
                                media += bytes
                                rendered += MTMD_MEDIA_MARKER
                            }
                            "input_audio" -> {
                                if (!modelHasAudioEncoder) throw TranslatorError.AudioWithoutAudioEncoder()
                                @Suppress("UNCHECKED_CAST")
                                val audioObj = part["input_audio"] as? Map<String, Any?>
                                    ?: throw TranslatorError.MalformedRequest("$path input_audio part missing input_audio object")
                                val dataB64 = audioObj["data"] as? String
                                    ?: throw TranslatorError.MalformedRequest("$path input_audio part missing input_audio.data")
                                val formatStr = audioObj["format"] as? String
                                    ?: throw TranslatorError.MalformedRequest("$path input_audio part missing input_audio.format")
                                if (formatStr !in SUPPORTED_AUDIO_FORMATS) {
                                    throw TranslatorError.UnsupportedAudioFormat(formatStr, SUPPORTED_AUDIO_FORMATS)
                                }
                                // Validate the format string against `AudioFormat`
                                // to keep the supported-format gate honest, but
                                // the production path no longer calls into
                                // AudioDecoder — mtmd does its own format
                                // detection by magic bytes.
                                AUDIO_FORMAT_BY_NAME[formatStr]
                                    ?: throw TranslatorError.UnsupportedAudioFormat(formatStr, SUPPORTED_AUDIO_FORMATS)
                                if (dataB64.isEmpty()) {
                                    throw TranslatorError.MalformedRequest("input_audio.data is empty")
                                }
                                val encoded = try {
                                    Base64.getDecoder().decode(dataB64)
                                } catch (e: IllegalArgumentException) {
                                    throw TranslatorError.MalformedRequest("input_audio.data is not valid base64")
                                }
                                // Pass the raw base64-decoded bytes (still in
                                // their original WAV/MP3/FLAC envelope) straight
                                // through to mtmd. `mtmd_helper_bitmap_init_from_buf`
                                // only accepts WAV/MP3/FLAC by magic-byte
                                // detection — feeding it headerless PCM (e.g.
                                // via `AudioDecoder.decode`) makes bitmap-init
                                // fail silently with mtmd error 52.
                                media += encoded
                                rendered += MTMD_MEDIA_MARKER
                            }
                            else -> throw TranslatorError.MalformedRequest("unsupported content part type: $type")
                        }
                    }
                }
                else -> throw TranslatorError.MalformedRequest(
                    "messages[$msgIdx].content must be a string or array of content parts",
                )
            }

            translated += LlamaTranslatedMessage(role = role, content = rendered.joinToString(" "))
        }

        return LlamaPromptInput(
            messagesWithMarkers = translated.toList(),
            media = media.toList(),
            prompt = promptParts.joinToString("\n"),
        )
    }

    companion object {
        /**
         * Audio formats this platform can decode. Anything outside the set
         * throws [TranslatorError.UnsupportedAudioFormat]. Android has ogg
         * (via `MediaCodec`); iOS has flac instead.
         */
        val SUPPORTED_AUDIO_FORMATS: List<String> = listOf("pcm16", "wav", "mp3", "m4a", "aac", "ogg")

        private val AUDIO_FORMAT_BY_NAME: Map<String, AudioFormat> = mapOf(
            "pcm16" to AudioFormat.PCM16,
            "wav" to AudioFormat.WAV,
            "mp3" to AudioFormat.MP3,
            "m4a" to AudioFormat.M4A,
            "aac" to AudioFormat.AAC,
            "ogg" to AudioFormat.OGG,
        )
    }
}
