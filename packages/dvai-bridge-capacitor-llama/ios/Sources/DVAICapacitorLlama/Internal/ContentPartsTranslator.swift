import Foundation

/// Output of `ContentPartsTranslator.translate(messages:)` — the raw inputs
/// the llama.cpp handler will hand to `mtmd_helper_eval` / `mtmd_helper_eval_audio`.
///
/// Phase 1 note: `prompt` is a simple newline-join of every `text` part across
/// every message, in source order. Task 36 will replace this with a real
/// chat-template render via `llama_chat_apply_template` against the loaded
/// model — the prompt here is effectively a debug / fallback string that the
/// handler may not even use directly.
struct LlamaPromptInput: Equatable {
    /// Concatenation of all `text` parts in order, joined with `"\n"`.
    let prompt: String
    /// Encoded image bytes (PNG / JPEG / etc.) per `image_url` part, in source
    /// order. Image format detection happens downstream inside llama.cpp.
    let images: [Data]
    /// 16 kHz mono PCM16-LE samples per `input_audio` part, in source order.
    let audioPCM: [Data]
}

/// Errors raised by `ContentPartsTranslator.translate(messages:)`. The HTTP
/// status mappings (per spec §8.5) are owned by the handler layer; the
/// translator just throws the typed case.
enum TranslatorError: Error, Equatable {
    /// 400 — `Request includes an image but no mmproj was loaded. Set nativeMmprojPath when starting.`
    case noMmprojForImage
    /// 400 — `Loaded model has no native audio encoder. Use a multimodal model like Gemma 4 or Phi-4 Multimodal.`
    case audioWithoutAudioEncoder
    /// 400 — `Unsupported audio format: <fmt>. Supported on this platform: <list>.`
    case unsupportedAudioFormat(String, supported: [String])
    /// 400 — `Audio decode failed: <reason>`.
    case audioDecodeFailed(String)
    /// 502 — `Failed to fetch image: <reason>`.
    case imageFetchFailed(String)
    /// 400 — `<reason>`. Used for shape errors (missing role, unknown part type, etc.).
    case malformedRequest(String)
}

/// Test seam for the image-decode collaborator. The default implementation
/// just delegates to `ImageDecoder.resolve(url:)`; tests can substitute a
/// canned-bytes mock so they don't have to round-trip through the real
/// data-URL / file / HTTP pipelines (those are covered in `ImageDecoderTest`).
protocol ImageDecoderProtocol {
    func resolve(url: String) async throws -> Data
}

struct DefaultImageDecoder: ImageDecoderProtocol {
    func resolve(url: String) async throws -> Data {
        try await ImageDecoder.resolve(url: url)
    }
}

/// Walks an OpenAI-style `messages` array and produces a `LlamaPromptInput`
/// bundle: text concatenated into `prompt`, images decoded via
/// `ImageDecoder`, audio base64-decoded then run through `AudioDecoder` to
/// 16 kHz mono PCM16-LE.
///
/// Audio data contract: `input_audio.data` must be standard base64 (RFC 4648
/// §4); URL-safe base64 (`-` / `_` chars) is rejected. This matches OpenAI's
/// documented input format.
///
/// Spec reference: §8.1 (content-part shape), §8.2 (image translation), §8.3
/// (audio translation), §8.5 (error mapping).
final class ContentPartsTranslator {
    /// Audio formats this platform can decode. Anything outside the set
    /// throws `unsupportedAudioFormat`. iOS has flac (via `AVAudioFile`);
    /// Android has ogg instead.
    static let supportedAudioFormats: [String] = ["pcm16", "wav", "mp3", "m4a", "aac", "flac"]

    private let mmprojLoaded: Bool
    private let modelHasAudioEncoder: Bool
    private let imageDecoder: ImageDecoderProtocol
    private let audioDecoder: (Data, AudioFormat) async throws -> Data

    init(
        mmprojLoaded: Bool,
        modelHasAudioEncoder: Bool,
        imageDecoder: ImageDecoderProtocol = DefaultImageDecoder(),
        audioDecoder: @escaping (Data, AudioFormat) async throws -> Data = { try await AudioDecoder.decode(data: $0, format: $1) }
    ) {
        self.mmprojLoaded = mmprojLoaded
        self.modelHasAudioEncoder = modelHasAudioEncoder
        self.imageDecoder = imageDecoder
        self.audioDecoder = audioDecoder
    }

    /// Translate an OpenAI `messages` array (as decoded JSON: `[String: Any]`
    /// per message) into a `LlamaPromptInput`. Walks each message's `content`
    /// in order; legacy string content is treated as a single text part.
    func translate(messages: [[String: Any]]) async throws -> LlamaPromptInput {
        var promptParts: [String] = []
        var images: [Data] = []
        var audioPCM: [Data] = []

        for (msgIdx, msg) in messages.enumerated() {
            guard msg["role"] is String else {
                throw TranslatorError.malformedRequest("messages[\(msgIdx)] missing string 'role'")
            }
            let content = msg["content"]
            if let text = content as? String {
                promptParts.append(text)
                continue
            }
            guard let parts = content as? [[String: Any]] else {
                throw TranslatorError.malformedRequest(
                    "messages[\(msgIdx)].content must be a string or array of content parts"
                )
            }
            for (partIdx, part) in parts.enumerated() {
                let path = "messages[\(msgIdx)].content[\(partIdx)]"
                guard let type = part["type"] as? String else {
                    throw TranslatorError.malformedRequest("\(path) missing string 'type'")
                }
                switch type {
                case "text":
                    guard let text = part["text"] as? String else {
                        throw TranslatorError.malformedRequest("\(path) text part missing string 'text'")
                    }
                    promptParts.append(text)
                case "image_url":
                    if !mmprojLoaded {
                        throw TranslatorError.noMmprojForImage
                    }
                    guard let imgObj = part["image_url"] as? [String: Any],
                          let url = imgObj["url"] as? String else {
                        throw TranslatorError.malformedRequest("\(path) image_url part missing image_url.url")
                    }
                    do {
                        let bytes = try await imageDecoder.resolve(url: url)
                        images.append(bytes)
                    } catch {
                        throw TranslatorError.imageFetchFailed(String(describing: error))
                    }
                case "input_audio":
                    if !modelHasAudioEncoder {
                        throw TranslatorError.audioWithoutAudioEncoder
                    }
                    guard let audioObj = part["input_audio"] as? [String: Any],
                          let dataB64 = audioObj["data"] as? String,
                          let formatStr = audioObj["format"] as? String else {
                        throw TranslatorError.malformedRequest(
                            "\(path) input_audio part missing input_audio.data or input_audio.format"
                        )
                    }
                    if !Self.supportedAudioFormats.contains(formatStr) {
                        throw TranslatorError.unsupportedAudioFormat(
                            formatStr,
                            supported: Self.supportedAudioFormats
                        )
                    }
                    guard let format = AudioFormat(rawValue: formatStr) else {
                        // The supportedAudioFormats list is the source of truth;
                        // this branch only fires if the raw-value enum diverges
                        // from that list.
                        throw TranslatorError.unsupportedAudioFormat(
                            formatStr,
                            supported: Self.supportedAudioFormats
                        )
                    }
                    guard !dataB64.isEmpty else {
                        throw TranslatorError.malformedRequest("input_audio.data is empty")
                    }
                    // Standard base64 only (RFC 4648 §4). URL-safe base64 (-/_ chars) is rejected.
                    // Matches OpenAI's documented input format.
                    guard let encodedBytes = Data(base64Encoded: dataB64) else {
                        throw TranslatorError.malformedRequest("input_audio.data is not valid base64")
                    }
                    do {
                        let pcm = try await audioDecoder(encodedBytes, format)
                        audioPCM.append(pcm)
                    } catch {
                        throw TranslatorError.audioDecodeFailed(String(describing: error))
                    }
                default:
                    throw TranslatorError.malformedRequest("unsupported content part type: \(type)")
                }
            }
        }

        return LlamaPromptInput(
            prompt: promptParts.joined(separator: "\n"),
            images: images,
            audioPCM: audioPCM
        )
    }
}
