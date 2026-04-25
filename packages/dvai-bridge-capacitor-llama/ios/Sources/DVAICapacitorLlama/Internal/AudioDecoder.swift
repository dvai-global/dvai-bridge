import Foundation
import AVFoundation

/// Supported audio encodings accepted by `AudioDecoder.decode(data:format:)`.
///
/// `pcm16` is treated as already-decoded raw little-endian 16 kHz mono PCM16
/// and returned unchanged. All other formats are decoded via
/// `AVAudioFile` + `AVAudioConverter` to that same target format.
enum AudioFormat: String {
    case pcm16, wav, mp3, m4a, aac, flac
}

/// Decodes supported audio formats to 16 kHz mono PCM16 little-endian samples
/// suitable for feeding into a multimodal projector.
struct AudioDecoder {
    /// Decode `data` (encoded in `format`) to 16 kHz mono PCM16 LE samples.
    /// Pass-through for `.pcm16`.
    static func decode(data: Data, format: AudioFormat) async throws -> Data {
        switch format {
        case .pcm16:
            return data
        case .wav, .mp3, .m4a, .aac, .flac:
            return try await decodeViaAVAudioFile(data: data)
        }
    }

    private static func decodeViaAVAudioFile(data: Data) async throws -> Data {
        // AVAudioFile requires a file URL, so write to a temp file first.
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let inputFile = try AVAudioFile(forReading: tmpURL)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(
                domain: "AudioDecoder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create output format"]
            )
        }
        guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: outputFormat) else {
            throw NSError(
                domain: "AudioDecoder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create converter"]
            )
        }
        guard
            let inputBuf = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: 4096),
            let outputBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)
        else {
            throw NSError(
                domain: "AudioDecoder",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate buffers"]
            )
        }

        var result = Data()
        while inputFile.framePosition < inputFile.length {
            try inputFile.read(into: inputBuf)

            // The input callback may be invoked multiple times per
            // `convert(to:error:withInputFrom:)` call. Without this guard the
            // same `inputBuf` would be re-emitted to the converter and we'd
            // double-count samples / corrupt output.
            var consumed = false
            var error: NSError?
            converter.convert(to: outputBuf, error: &error) { _, status in
                if consumed {
                    status.pointee = .endOfStream
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return inputBuf
            }
            if let error = error { throw error }

            if let int16Data = outputBuf.int16ChannelData {
                let frameLength = Int(outputBuf.frameLength)
                if frameLength > 0 {
                    let bytes = UnsafeRawPointer(int16Data[0])
                    result.append(Data(bytes: bytes, count: frameLength * 2))
                }
            }
        }

        // Drain: tell the converter we're done so any buffered tail samples
        // (e.g. AAC priming / codec lookahead) are flushed to outputBuf.
        var drainError: NSError?
        let drainStatus = converter.convert(to: outputBuf, error: &drainError) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        if drainStatus == .haveData, drainError == nil, let int16Data = outputBuf.int16ChannelData {
            let frameLength = Int(outputBuf.frameLength)
            if frameLength > 0 {
                let bytes = UnsafeRawPointer(int16Data[0])
                result.append(Data(bytes: bytes, count: frameLength * 2))
            }
        }
        // drainError on flush is acceptable — some codecs return an error when there's nothing left.

        return result
    }
}
