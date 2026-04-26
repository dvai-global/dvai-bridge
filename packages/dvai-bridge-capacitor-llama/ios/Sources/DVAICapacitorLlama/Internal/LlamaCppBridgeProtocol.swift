// Internal/LlamaCppBridgeProtocol.swift
import Foundation
import DVAICapacitorLlamaObjC

/// Test seam over the ObjC++ `LlamaCppBridge`. Concrete `LlamaCppBridge`
/// conforms via the extension below; `LlamaHandlers` takes this protocol so
/// unit tests can substitute a canned-response fake without loading a real
/// GGUF model. Mirrors the `ImageDecoderProtocol` pattern used by Task 35's
/// `ContentPartsTranslator`.
///
/// The two inference methods use Swift's automatic NSError-bridging — they
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

    // Phase 2A Pass 1: multimodal projector (mmproj) lifecycle. Pass 1 is
    // stubbed -- `loadMmproj` records the path but doesn't actually
    // initialize an mtmd_context. Pass 2 will swap in real mtmd calls.
    var isMmprojLoaded: Bool { get }
    func loadMmproj(atPath path: String) throws
    func unloadMmproj()
}

extension LlamaCppBridge: LlamaCppBridgeProtocol {}
