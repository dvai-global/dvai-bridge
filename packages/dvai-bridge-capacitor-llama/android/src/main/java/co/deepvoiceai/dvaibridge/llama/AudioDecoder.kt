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
            // These start from the input track's format but may be refreshed
            // when MediaCodec emits INFO_OUTPUT_FORMAT_CHANGED below — for
            // codecs like AAC LC / HE-AAC v2 the decoder's actual output rate
            // and channel layout (post-SBR/PS) are only known after the first
            // decoded buffer. They must therefore be `var`.
            var srcSampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var srcChannels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            codec = MediaCodec.createDecoderByType(mime).apply {
                configure(inputFormat, null, null, 0)
                start()
            }

            val pcmBytes = ByteArrayOutputStream()
            val info = MediaCodec.BufferInfo()
            var sawInputEOS = false
            var sawOutputEOS = false
            val timeoutUs = 10_000L
            // Bound the dequeue loop: if the codec produces no output for
            // ~10 seconds (driver bug or malformed input that never reaches
            // EOS), throw rather than spinning forever.
            val maxNoProgressIterations = 1000
            var noProgressIterations = 0

            while (!sawOutputEOS) {
                var producedThisIteration = false
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
                        producedThisIteration = true
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, timeoutUs)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        // Refresh the rate / channel count from the codec's
                        // actual output format — this is the authoritative
                        // value for HE-AAC and similar codecs that change
                        // shape after the first decoded buffer.
                        val newFormat = codec.outputFormat
                        srcSampleRate = newFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        srcChannels = newFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        producedThisIteration = true
                    }
                    outIdx >= 0 -> {
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
                        producedThisIteration = true
                    }
                    // INFO_TRY_AGAIN_LATER and INFO_OUTPUT_BUFFERS_CHANGED
                    // (deprecated) fall through — just loop again.
                }
                if (producedThisIteration) {
                    noProgressIterations = 0
                } else if (++noProgressIterations >= maxNoProgressIterations) {
                    throw IllegalStateException(
                        "MediaCodec produced no output for " +
                            "${maxNoProgressIterations * 10}ms — likely hung",
                    )
                }
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
            // sum is in 32-bit Int; for PCM16 ±32767 across N channels,
            // |sum| <= N*32768, division returns valid PCM16 — no clipping needed.
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
