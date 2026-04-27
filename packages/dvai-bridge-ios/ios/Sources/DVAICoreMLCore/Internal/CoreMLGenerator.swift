import Foundation
import CoreML

/// Orchestrates `CoreMLEngine` + `CoreMLTokenizer` + `CoreMLSampler` to
/// produce text from a prompt via autoregressive decoding.
///
/// CoreML prediction note (iOS 18):
///   `MLModel.prediction(from:using:options:)` is synchronous. We wrap the
///   decode loop in a `Task.detached` (in `generateStream`) or simply call
///   `runStep` directly in the async context for `generate`. Since `runStep`
///   is not itself `async`, calling it in an `async` function does NOT suspend
///   — it runs inline on the current executor. For long-running decodes the
///   caller should call `generate` / `generateStream` from a background Task
///   to avoid blocking the main actor.
@available(iOS 18.0, macOS 15.0, *)
internal struct CoreMLGenerator: @unchecked Sendable {
    let engine: CoreMLEngine
    let tokenizer: CoreMLTokenizer
    let sampler: CoreMLSampler
    let maxNewTokens: Int

    /// Buffered generation. Runs the full decode loop and returns the decoded text.
    func generate(promptTokens: [Int]) async throws -> String {
        return try await Task.detached(priority: .userInitiated) {
            guard !promptTokens.isEmpty else {
                throw CoreMLBackendError.generationFailed(reason: "prompt tokens are empty")
            }

            var generated: [Int] = []
            let state = self.engine.makeConversationState()

            // Prefill + decode unified: each runStep returns logits for the
            // *next* token at position (kvPos+1). After feeding all prompt
            // tokens, the last logits give us our first generated token.
            // (Previous iteration of this code re-fed promptTokens.last as a
            // separate step, which double-counted that token in the KV
            // cache.)
            var kvPos = 0
            var lastLogits: MLMultiArray = try self.engine.runStep(
                token: promptTokens[0], kvCachePosition: 0, state: state
            )
            kvPos = 1
            for token in promptTokens.dropFirst() {
                lastLogits = try self.engine.runStep(
                    token: token, kvCachePosition: kvPos, state: state
                )
                kvPos += 1
            }

            var nextToken = self.sampler.sample(logits: lastLogits)

            for _ in 0 ..< self.maxNewTokens {
                if nextToken == self.engine.eosTokenId { break }
                generated.append(nextToken)
                lastLogits = try self.engine.runStep(
                    token: nextToken, kvCachePosition: kvPos, state: state
                )
                kvPos += 1
                nextToken = self.sampler.sample(logits: lastLogits)
            }

            return self.tokenizer.decode(tokens: generated)
        }.value
    }

    /// Streaming generation. Yields each decoded token chunk via `AsyncThrowingStream`.
    func generateStream(promptTokens: [Int]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    guard !promptTokens.isEmpty else {
                        throw CoreMLBackendError.generationFailed(reason: "prompt tokens are empty")
                    }

                    let state = self.engine.makeConversationState()

                    var kvPos = 0
                    var lastLogits: MLMultiArray = try self.engine.runStep(
                        token: promptTokens[0], kvCachePosition: 0, state: state
                    )
                    kvPos = 1
                    for token in promptTokens.dropFirst() {
                        lastLogits = try self.engine.runStep(
                            token: token, kvCachePosition: kvPos, state: state
                        )
                        kvPos += 1
                    }

                    var nextToken = self.sampler.sample(logits: lastLogits)

                    for _ in 0 ..< self.maxNewTokens {
                        if nextToken == self.engine.eosTokenId { break }
                        let chunk = self.tokenizer.decode(token: nextToken)
                        continuation.yield(chunk)
                        lastLogits = try self.engine.runStep(
                            token: nextToken, kvCachePosition: kvPos, state: state
                        )
                        kvPos += 1
                        nextToken = self.sampler.sample(logits: lastLogits)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
