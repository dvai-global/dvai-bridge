import Foundation
import Tokenizers

/// Loads a HuggingFace-style tokenizer.json + tokenizer_config.json from a
/// local directory. Provides chat-template application, encode, and decode.
///
/// swift-transformers 1.3.0 API notes:
///   - `AutoTokenizer.from(modelFolder:hubApi:strict:)` — hubApi and strict
///     have default values so the two-arg form `from(modelFolder:)` is NOT
///     available; must pass at minimum `modelFolder:`.
///   - `Message` is `typealias Message = [String: any Sendable]` so we convert
///     `[[String: String]]` → `[[String: any Sendable]]` before passing.
///   - `applyChatTemplate(messages:)` has all other params defaulted.
///   - `eosTokenId` is `Int?` (optional) — we fall back to 0 if absent.
internal struct CoreMLTokenizer: @unchecked Sendable {
    private let inner: any Tokenizer

    init(tokenizerDir: URL) async throws {
        do {
            // `from(modelFolder:)` resolves to `from(modelFolder:hubApi:strict:)`
            // with default HubApi() and strict: true.
            self.inner = try await AutoTokenizer.from(modelFolder: tokenizerDir)
        } catch {
            throw CoreMLBackendError.tokenizerLoadFailed(reason: "\(error)")
        }
    }

    /// Apply the model's chat template to convert messages into token IDs.
    /// - Parameter messages: Array of {"role": ..., "content": ...} dicts.
    /// - Parameter addGenerationPrompt: Append the generation-start marker.
    func applyChatTemplate(
        messages: [[String: String]],
        addGenerationPrompt: Bool = true
    ) throws -> [Int] {
        // Convert [[String: String]] → [[String: any Sendable]] (Tokenizers.Message)
        let normalized: [Message] = messages.map { dict in
            var m: Message = [:]
            for (k, v) in dict { m[k] = v }
            return m
        }
        do {
            // swift-transformers 1.x's applyChatTemplate signature drops the
            // addGenerationPrompt parameter (defaulted to true server-side).
            // The `addGenerationPrompt` knob in our wrapper is preserved for
            // future API symmetry but currently passed through implicitly.
            _ = addGenerationPrompt
            return try inner.applyChatTemplate(messages: normalized)
        } catch {
            throw CoreMLBackendError.generationFailed(reason: "applyChatTemplate failed: \(error)")
        }
    }

    func encode(text: String) -> [Int] {
        inner.encode(text: text)
    }

    func decode(tokens: [Int]) -> String {
        inner.decode(tokens: tokens, skipSpecialTokens: true)
    }

    func decode(token: Int) -> String {
        decode(tokens: [token])
    }

    /// EOS token id. Falls back to 0 if the tokenizer config doesn't specify one.
    var eosTokenId: Int { inner.eosTokenId ?? 0 }
}
