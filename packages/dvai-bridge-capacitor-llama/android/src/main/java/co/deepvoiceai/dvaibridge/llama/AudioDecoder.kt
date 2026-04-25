package co.deepvoiceai.dvaibridge.llama

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * Supported audio encodings accepted by [AudioDecoder.decode]. `PCM16` is
 * treated as already-decoded raw little-endian 16 kHz mono PCM16 and returned
 * unchanged. All other formats are decoded via `MediaExtractor` + `MediaCodec`,
 * then downmixed to mono and resampled (linear interpolation) to 16 kHz.
 */
enum class AudioFormat { PCM16, WAV, MP3, M4A, AAC, FLAC }

/**
 * Decodes supported audio formats to 16 kHz mono PCM16 little-endian samples
 * suitable for feeding into a multimodal projector.
 */
object AudioDecoder {
    /**
     * Decode [data] (encoded in [format]) to 16 kHz mono PCM16 LE samples.
     * Pass-through for [AudioFormat.PCM16]. Note: [MediaCodec] is not
     * available in JVM unit tests, so non-pass-through paths are exercised
     * only by the instrumented test suite.
     */
    fun decode(data: ByteArray, format: AudioFormat): ByteArray {
        if (format == AudioFormat.PCM16) return data
        // MediaExtractor wants a file path, so spill the encoded bytes to a
        // temp file. The temp file is removed in the finally block regardless
        // of whether decoding throws.
        val tmp = File.createTempFile("dvai-audio-", ".bin").apply {
            FileOutputStream(this).use { it.write(data) }
        }
        try {
            return decodeViaMediaCodec(tmp.absolutePath)
        } finally {
            tmp.delete()
        }
    }

    private fun decodeViaMediaCodec(path: String): ByteArray {
        val extractor = MediaExtractor().apply { setDataSource(path) }
        var codec: MediaCodec? = null
        try {
            // Find the first audio track.
            var trackIndex = -1
            var inputFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    inputFormat = f
                    break
                }
            }
            require(trackIndex >= 0) { "No audio track found" }
            extractor.selectTrack(trackIndex)

            val mime = inputFormat!!.getString(MediaFormat.KEY_MIME)!!
            val srcSampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val srcChannels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            codec = MediaCodec.createDecoderByType(mime).apply {
                configure(inputFormat, null, null, 0)
                start()
            }

            val pcmBytes = ByteArrayOutputStream()
            val info = MediaCodec.BufferInfo()
            var sawInputEOS = false
            var sawOutputEOS = false
            val timeoutUs = 10_000L

            while (!sawOutputEOS) {
                if (!sawInputEOS) {
                    val inIdx = codec.dequeueInputBuffer(timeoutUs)
                    if (inIdx >= 0) {
                        val inBuf = codec.getInputBuffer(inIdx)!!
                        val n = extractor.readSampleData(inBuf, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(
                                inIdx, 0, 0, 0L,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            sawInputEOS = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, n, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, timeoutUs)
                if (outIdx >= 0) {
                    if (info.size > 0) {
                        val outBuf = codec.getOutputBuffer(outIdx)!!
                        val chunk = ByteArray(info.size)
                        outBuf.position(info.offset)
                        outBuf.limit(info.offset + info.size)
                        outBuf.get(chunk)
                        pcmBytes.write(chunk)
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        sawOutputEOS = true
                    }
                }
                // outIdx < 0 cases (try-again-later, format-changed,
                // buffers-changed) are handled implicitly by looping again.
            }

            val raw = pcmBytes.toByteArray()
            val mono = if (srcChannels > 1) downmixToMono(raw, srcChannels) else raw
            return if (srcSampleRate != 16000) resampleLinear(mono, srcSampleRate, 16000) else mono
        } finally {
            try { codec?.stop() } catch (_: Exception) { /* ignore */ }
            try { codec?.release() } catch (_: Exception) { /* ignore */ }
            try { extractor.release() } catch (_: Exception) { /* ignore */ }
        }
    }

    /** Average all channels per frame to produce a mono PCM16 LE byte stream. */
    private fun downmixToMono(input: ByteArray, channels: Int): ByteArray {
        val frames = input.size / (2 * channels)
        val out = ByteArray(frames * 2)
        val sb = ByteBuffer.wrap(input).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val ob = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        for (f in 0 until frames) {
            var sum = 0
            for (c in 0 until channels) sum += sb.get(f * channels + c).toInt()
            ob.put(f, (sum / channels).toShort())
        }
        return out
    }

    /**
     * Linear-interpolation resampler for mono PCM16 LE. Adequate for
     * speech-band audio fed into multimodal projectors; for higher quality
     * we'd want a polyphase FIR, but that's out of scope here.
     */
    private fun resampleLinear(src: ByteArray, srcRate: Int, dstRate: Int): ByteArray {
        val srcSamples = src.size / 2
        if (srcSamples == 0) return ByteArray(0)
        val dstSamples = ((srcSamples.toLong() * dstRate) / srcRate).toInt()
        val out = ByteArray(dstSamples * 2)
        val sb = ByteBuffer.wrap(src).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val ob = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        for (i in 0 until dstSamples) {
            val srcPos = i.toDouble() * srcRate / dstRate
            val a = srcPos.toInt().coerceIn(0, srcSamples - 1)
            val b = (a + 1).coerceIn(0, srcSamples - 1)
            val frac = srcPos - a
            val s = (sb.get(a) * (1 - frac) + sb.get(b) * frac).roundToInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            ob.put(i, s.toShort())
        }
        return out
    }
}
