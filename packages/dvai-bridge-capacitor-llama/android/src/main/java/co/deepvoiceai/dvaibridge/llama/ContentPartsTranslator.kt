package co.deepvoiceai.dvaibridge.llama

import java.util.Base64

/**
 * Output of [ContentPartsTranslator.translate] — the raw inputs the llama.cpp
 * handler will hand to `mtmd_helper_eval` / `mtmd_helper_eval_audio`.
 *
 * Phase 1 note: [prompt] is a simple newline-join of every `text` part across
 * every message, in source order. Task 36 will replace this with a real
 * chat-template render via `llama_chat_apply_template` against the loaded
 * model — the prompt here is effectively a debug / fallback string that the
 * handler may not even use directly.
 */
data class LlamaPromptInput(
    /** Concatenation of all `text` parts in order, joined with `"\n"`. */
    val prompt: String,
    /** Encoded image bytes per `image_url` part, in source order. */
    val images: List<ByteArray>,
    /** 16 kHz mono PCM16-LE samples per `input_audio` part, in source order. */
    val audioPCM: List<ByteArray>,
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
 * bundle: text concatenated into [LlamaPromptInput.prompt], images decoded
 * via the injected [imageDecoder] collaborator, audio base64-decoded then
 * run through [audioDecoder] to 16 kHz mono PCM16-LE.
 *
 * Spec reference: §8.1 (content-part shape), §8.2 (image translation), §8.3
 * (audio translation), §8.5 (error mapping).
 *
 * @param mmprojLoaded whether a multimodal projector is available — gates
 *   image parts (no mmproj → throw [TranslatorError.NoMmprojForImage]).
 * @param modelHasAudioEncoder whether the loaded model has a native audio
 *   encoder — gates audio parts (no encoder → throw
 *   [TranslatorError.AudioWithoutAudioEncoder]).
 * @param imageDecoder injected image-resolve function (defaults to
 *   [ImageDecoder.resolve]). Tests substitute a canned-bytes mock so they
 *   don't have to round-trip the real data-URL / file / HTTP pipelines —
 *   those are covered by `ImageDecoderTest`.
 * @param audioDecoder injected audio-decode function (defaults to
 *   [AudioDecoder.decode]). Tests inject a recorder closure to assert what
 *   was passed in without exercising MediaCodec (which is unavailable in
 *   JVM unit tests).
 */
class ContentPartsTranslator(
    private val mmprojLoaded: Boolean,
    private val modelHasAudioEncoder: Boolean,
    private val imageDecoder: (String) -> ByteArray = { url -> ImageDecoder.resolve(url) },
    private val audioDecoder: (ByteArray, AudioFormat) -> ByteArray = AudioDecoder::decode,
) {
    /**
     * Translate an OpenAI `messages` list (decoded JSON: `Map<String, Any?>`
     * per message) into a [LlamaPromptInput]. Walks each message's `content`
     * in order; legacy string content is treated as a single text part.
     */
    suspend fun translate(messages: List<Map<String, Any?>>): LlamaPromptInput {
        val promptParts = mutableListOf<String>()
        val images = mutableListOf<ByteArray>()
        val audioPCM = mutableListOf<ByteArray>()

        for ((msgIdx, msg) in messages.withIndex()) {
            if (msg["role"] !is String) {
                throw TranslatorError.MalformedRequest("messages[$msgIdx] missing string 'role'")
            }
            when (val content = msg["content"]) {
                is String -> promptParts += content
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
                                images += bytes
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
                                val format = AUDIO_FORMAT_BY_NAME[formatStr]
                                    // SUPPORTED_AUDIO_FORMATS is the source of truth; this branch only
                                    // fires if the enum diverges from the supported-list table.
                                    ?: throw TranslatorError.UnsupportedAudioFormat(formatStr, SUPPORTED_AUDIO_FORMATS)
                                val encoded = try {
                                    Base64.getDecoder().decode(dataB64)
                                } catch (e: IllegalArgumentException) {
                                    throw TranslatorError.AudioDecodeFailed("base64 decode failed: ${e.message}")
                                }
                                val pcm = try {
                                    audioDecoder(encoded, format)
                                } catch (e: Exception) {
                                    throw TranslatorError.AudioDecodeFailed(e.message ?: e::class.java.simpleName)
                                }
                                audioPCM += pcm
                            }
                            else -> throw TranslatorError.MalformedRequest("unsupported content part type: $type")
                        }
                    }
                }
                else -> throw TranslatorError.MalformedRequest(
                    "messages[$msgIdx].content must be a string or array of content parts",
                )
            }
        }

        return LlamaPromptInput(
            prompt = promptParts.joinToString("\n"),
            images = images.toList(),
            audioPCM = audioPCM.toList(),
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
