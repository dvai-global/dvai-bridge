import Foundation

/// The canonical media-marker token mtmd uses for image/audio splice points.
/// Mirrors `mtmd_default_marker()` from `tools/mtmd/mtmd.h`. Substituting this
/// literal lets us avoid an FFI call from this translation unit.
let MTMD_MEDIA_MARKER = "<__media__>"

/// One rendered chat message ready for `bridge.applyChatTemplate(...)`.
/// Content has had image_url / input_audio parts replaced with the
/// `<__media__>` marker; the corresponding raw bytes live in
/// `LlamaPromptInput.media` in the same declaration order as the markers.
struct LlamaTranslatedMessage: Equatable {
    let role: String
    let content: String
}

/// Output of `ContentPartsTranslator.translate(messages:)` — the inputs
/// the llama.cpp handler will hand to `bridge.applyChatTemplate(...)` and
/// `bridge.completeMultimodalPrompt(...)`.
struct LlamaPromptInput: Equatable {
    /// Per-message rendered content with media replaced by `<__media__>`
    /// markers, in source order. Pass directly to `applyChatTemplate`.
    let messagesWithMarkers: [LlamaTranslatedMessage]
    /// All media bytes (images + decoded audio) in declaration order across
    /// all messages, matching the order the markers appear in the rendered
    /// content. mtmd's `tokenize` matches markers to bitmaps by position;
    /// it auto-detects image vs audio by magic bytes, so a single ordered
    /// list is sufficient.
    let media: [Data]
    /// Legacy: concatenation of all `text` parts for diagnostics. The handler
    /// no longer feeds this to the model directly — `messagesWithMarkers` +
    /// `media` is the source of truth — but it stays available for logging.
    let prompt: String
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
/// bundle. Each message's content is rendered into a string with media parts
/// replaced by `<__media__>` markers; the corresponding bytes (image bytes
/// from `ImageDecoder` and the raw base64-decoded audio bytes — still in
/// their WAV/MP3/FLAC envelope) are appended to `media` in declaration order.
///
/// mtmd does its own format detection (via miniaudio) inside
/// `mtmd_helper_bitmap_init_from_buf` by inspecting magic bytes, so the
/// translator must hand it the original encoded audio rather than headerless
/// PCM samples — `mtmd_helper_bitmap_init_from_buf` only recognizes
/// WAV/MP3/FLAC and would fail silently on raw PCM.
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
    /// Currently unused on the production path — mtmd handles audio decoding
    /// internally via miniaudio, so we pass the raw base64-decoded bytes (in
    /// their WAV/MP3/FLAC envelope) straight through. Kept as an init
    /// parameter for backward compatibility with existing tests and as a
    /// possible future fallback for formats mtmd cannot decode itself.
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
        var translatedMessages: [LlamaTranslatedMessage] = []
        var media: [Data] = []
        var promptParts: [String] = []

        for (msgIdx, msg) in messages.enumerated() {
            guard let role = msg["role"] as? String else {
                throw TranslatorError.malformedRequest("messages[\(msgIdx)] missing string 'role'")
            }
            let content = msg["content"]
            // Per-message rendered string (text segments + markers in order).
            var renderedSegments: [String] = []

            if let text = content as? String {
                promptParts.append(text)
                renderedSegments.append(text)
                translatedMessages.append(LlamaTranslatedMessage(role: role, content: renderedSegments.joined(separator: " ")))
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
                    renderedSegments.append(text)
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
                        media.append(bytes)
                    } catch {
                        throw TranslatorError.imageFetchFailed(String(describing: error))
                    }
                    renderedSegments.append(MTMD_MEDIA_MARKER)
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
                    // Validate the format string against `AudioFormat` to keep
                    // the supported-format gate honest, but the production
                    // path no longer calls into AudioDecoder — mtmd does its
                    // own format detection by magic bytes.
                    guard AudioFormat(rawValue: formatStr) != nil else {
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
                    // Pass the raw base64-decoded bytes (still in their
                    // original WAV/MP3/FLAC envelope) straight through to
                    // mtmd. `mtmd_helper_bitmap_init_from_buf` only accepts
                    // WAV/MP3/FLAC by magic-byte detection — feeding it
                    // headerless PCM (e.g. via `AudioDecoder.decode`) makes
                    // bitmap-init fail silently with mtmd error 52.
                    media.append(encodedBytes)
                    renderedSegments.append(MTMD_MEDIA_MARKER)
                default:
                    throw TranslatorError.malformedRequest("unsupported content part type: \(type)")
                }
            }
            // Join the rendered segments with spaces so adjacent text+marker
            // pairs become "before <__media__> after". A single space matches
            // the canonical mtmd-cli prompt shape.
            translatedMessages.append(
                LlamaTranslatedMessage(role: role, content: renderedSegments.joined(separator: " "))
            )
        }

        return LlamaPromptInput(
            messagesWithMarkers: translatedMessages,
            media: media,
            prompt: promptParts.joined(separator: "\n")
        )
    }
}
