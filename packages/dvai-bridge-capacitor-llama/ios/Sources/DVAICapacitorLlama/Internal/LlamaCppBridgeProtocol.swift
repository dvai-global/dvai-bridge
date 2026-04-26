// Internal/LlamaCppBridgeProtocol.swift
import Foundation
import DVAICapacitorLlamaObjC

/// Test seam over the ObjC++ `LlamaCppBridge`. Concrete `LlamaCppBridge`
/// conforms via the extension below; `LlamaHandlers` takes this protocol so
/// unit tests can substitute a canned-response fake without loading a real
/// GGUF model. Mirrors the `ImageDecoderProtocol` pattern used by Task 35's
/// `ContentPartsTranslator`.
///
/// The inference methods use Swift's automatic NSError-bridging — they
/// match the `(NSString *) … error:(NSError **)` ObjC selector and so are
/// imported as `throws -> String` / `throws -> [NSNumber]`.
protocol LlamaCppBridgeProtocol: AnyObject {
    var isLoaded: Bool { get }
    func completePrompt(
        _ prompt: String,
        maxTokens: Int32,
        temperature: Float,
        topP: Float
    ) throws -> String
    func embedding(_ text: String) throws -> [NSNumber]

    // Phase 2A Pass 2: real multimodal projector (mmproj) lifecycle +
    // chat-template + multimodal completion.
    var isMmprojLoaded: Bool { get }
    func loadMmproj(atPath path: String) throws
    func unloadMmproj()
    /// Whether the loaded model declares an audio encoder (mtmd_support_audio).
    /// Always false when mmproj is not loaded.
    func hasAudioEncoder() -> Bool

    /// Apply `llama_chat_apply_template`. `templateOverride` nil/empty falls
    /// back to the model's bundled chat template. Each message dict must have
    /// `role` and `content` string entries. Returns the rendered prompt string.
    func applyChatTemplate(
        _ templateOverride: String?,
        messages: [[String: String]],
        addAssistant: Bool
    ) throws -> String

    /// Multimodal completion. The prompt must contain N `<__media__>` markers
    /// matching `media.count`; bytes are auto-detected as image vs audio
    /// (image: PNG/JPEG/etc.; audio: WAV/MP3/FLAC).
    func completeMultimodalPrompt(
        _ prompt: String,
        media: [Data],
        maxTokens: Int32,
        temperature: Float,
        topP: Float
    ) throws -> String
}

// Concrete `LlamaCppBridge` (ObjC class) gets the four new methods via its
// imported ObjC selectors; the existing ones (completePrompt, embedding,
// loadMmproj, isMmprojLoaded) already conform from Pass 1.
extension LlamaCppBridge: LlamaCppBridgeProtocol {}
