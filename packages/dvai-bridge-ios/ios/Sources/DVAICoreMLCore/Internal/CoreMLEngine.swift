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
    let inputName: String       // default: "inputIds"
    let outputName: String      // default: "logits"
    let maxContextTokens: Int   // from opts; default 2048
    let eosTokenId: Int         // from tokenizer or opts

    init(
        modelURL: URL,
        inputName: String = "inputIds",
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
    /// Uses `MLModel.prediction(from:using:options:)` — the `using:` label
    /// carries the `MLState` object (not `state:`). Verified against Apple docs.
    func runStep(token: Int, state: MLState) throws -> MLMultiArray {
        let inputArr = try MLMultiArray(shape: [1, 1], dataType: .int32)
        inputArr[[0, 0] as [NSNumber]] = NSNumber(value: token)
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: inputArr])
        // `prediction(from:using:options:)` is synchronous in Apple's CoreML iOS 18 API.
        // Wrapped in CoreMLGenerator via async Task to avoid blocking the caller's thread.
        let output = try model.prediction(from: input, using: state, options: MLPredictionOptions())
        guard let logits = output.featureValue(for: outputName)?.multiArrayValue else {
            throw CoreMLBackendError.generationFailed(reason: "no '\(outputName)' output in model prediction")
        }
        return logits
    }
}
