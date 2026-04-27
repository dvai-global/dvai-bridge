import Foundation
import CoreML

/// Wraps an `MLModel` plus the shape conventions our CoreML LLM checkpoints
/// follow. `makeConversationState()` produces a fresh `MLState` for each
/// conversation so token-by-token decoding can preserve KV-cache across calls.
///
/// iOS 18 / macOS 15 API notes:
///   - `MLModel.makeState()` returns `MLState` (non-optional, throws is not in
///     the signature — it can still crash at runtime on non-stateful models).
///   - `MLModel.prediction(from:using:options:)` takes state via the `using:`
///     label, NOT `state:`. Verified against Apple's CoreML docs.
@available(iOS 18.0, macOS 15.0, *)
internal final class CoreMLEngine: @unchecked Sendable {
    let model: MLModel
    /// Name of the token-id input feature. Apple-converted Llama-3.2 stateful
    /// checkpoints use `input_ids` (snake_case, matching HF / PyTorch
    /// convention). Override via `opts["coremlInputName"]` for non-standard
    /// checkpoints.
    let inputName: String
    /// Name of the causal-mask input feature. Apple-converted stateful
    /// checkpoints declare a `causal_mask` Float16 multiarray of shape
    /// `[1, 1, q_len, kv_len]` — the model uses it inside
    /// `Ios18.scaledDotProductAttention`. Empty string disables the
    /// causal-mask input (for older or simpler checkpoints that don't
    /// declare it). Override via `opts["coremlCausalMaskName"]`.
    let causalMaskName: String
    let outputName: String      // default: "logits"
    let maxContextTokens: Int   // from opts; default 2048
    let eosTokenId: Int         // from tokenizer or opts

    init(
        modelURL: URL,
        inputName: String = "input_ids",
        causalMaskName: String = "causal_mask",
        outputName: String = "logits",
        maxContextTokens: Int = 2048,
        eosTokenId: Int,
        computeUnits: MLComputeUnits = .all
    ) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        do {
            self.model = try MLModel(contentsOf: modelURL, configuration: cfg)
        } catch {
            throw CoreMLBackendError.modelLoadFailed(reason: "\(error)")
        }
        self.inputName = inputName
        self.causalMaskName = causalMaskName
        self.outputName = outputName
        self.maxContextTokens = maxContextTokens
        self.eosTokenId = eosTokenId
    }

    /// Make a fresh KV-cache state for a new conversation.
    /// Wraps `MLModel.makeState()` (iOS 18 / macOS 15).
    /// Note: `makeState()` is NOT throwing in Apple's API; it returns `MLState`
    /// directly. Non-stateful models will produce a state object that has no
    /// effect — they won't crash here, but predictions will behave as if
    /// stateless. Real validation happens at prediction time.
    func makeConversationState() -> MLState {
        // matches MLModel.makeState() iOS 18 non-throwing signature
        return model.makeState()
    }

    /// Run a single-token forward pass using the given KV-cache state.
    ///
    /// Uses `MLModel.prediction(from:using:options:)` — the `using:` label
    /// carries the `MLState` object (not `state:`). Verified against Apple docs.
    ///
    /// - Parameters:
    ///   - token: New token id to feed (the K/V is appended to `state` by
    ///     the model's `Ios18.writeState` op as a side-effect).
    ///   - kvCachePosition: 0-based position of the new token in the
    ///     conversation. The first prompt token is position 0, second is 1,
    ///     etc. Used to size the causal-mask input. Caller increments this
    ///     across runStep calls within the same conversation.
    ///   - state: KV-cache `MLState` from `makeConversationState()`.
    func runStep(token: Int, kvCachePosition: Int, state: MLState) throws -> MLMultiArray {
        var features: [String: MLFeatureValue] = [:]

        // input_ids: [1, 1] Int32 with the new token. Direct memory write
        // (rather than NSNumber subscript) matches Apple's documented
        // pattern for primitive multiarray data and avoids unnecessary
        // bridging overhead.
        //
        // Note: the iOS Simulator's CoreML runtime emits
        // "Cannot retrieve vector from IRValue form int32" at predict
        // time on some stateful 4-bit MIL graphs regardless of how the
        // input is encoded. That's a simulator-only IR-layer
        // limitation; the integration test catches the pattern and
        // skips. macOS-native and real iOS devices run the same input
        // path end-to-end.
        let inputArr = try MLMultiArray(shape: [1, 1], dataType: .int32)
        inputArr.dataPointer.bindMemory(to: Int32.self, capacity: 1).pointee = Int32(token)
        features[inputName] = MLFeatureValue(multiArray: inputArr)

        // causal_mask: [1, 1, 1, kvCachePosition+1] Float16, all zeros.
        //
        // For autoregressive single-token decoding the new query attends to
        // every K/V position seen so far (0..kvCachePosition inclusive), so
        // the mask is all-zeros (zero = unmasked, large-negative = masked).
        // Apple's stateful Llama-3.2 checkpoints declare this input as
        // Float16 with shape flexibility `[1, 1, 1...2048, 1...2048]`; we
        // produce the minimal slice for the current step.
        if !causalMaskName.isEmpty,
           model.modelDescription.inputDescriptionsByName[causalMaskName] != nil
        {
            let kvLen = max(1, kvCachePosition + 1)
            let mask = try MLMultiArray(shape: [1, 1, 1, NSNumber(value: kvLen)], dataType: .float16)
            // Float16 zero == bit pattern 0x0000, so memset(0) suffices.
            memset(mask.dataPointer, 0, mask.count * MemoryLayout<UInt16>.size)
            features[causalMaskName] = MLFeatureValue(multiArray: mask)
        }

        let input = try MLDictionaryFeatureProvider(dictionary: features)
        // `prediction(from:using:options:)` is synchronous in Apple's CoreML iOS 18 API.
        // Wrapped in CoreMLGenerator via async Task to avoid blocking the caller's thread.
        let output = try model.prediction(from: input, using: state, options: MLPredictionOptions())
        guard let logits = output.featureValue(for: outputName)?.multiArrayValue else {
            throw CoreMLBackendError.generationFailed(reason: "no '\(outputName)' output in model prediction")
        }
        return logits
    }
}
