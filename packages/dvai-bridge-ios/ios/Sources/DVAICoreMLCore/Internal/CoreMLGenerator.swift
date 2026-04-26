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
            var generated: [Int] = []
            let state = self.engine.makeConversationState()

            // Prefill: run all prompt tokens through to build KV-cache.
            // Step-by-step (single-token input) — most Apple CoreML LLM
            // checkpoints accept [1, 1] input shape.
            guard !promptTokens.isEmpty else {
                throw CoreMLBackendError.generationFailed(reason: "prompt tokens are empty")
            }
            for token in promptTokens {
                _ = try self.engine.runStep(token: token, state: state)
            }

            // Decode loop: sample the next token using the final prefill output.
            let firstLogits = try self.engine.runStep(token: promptTokens.last!, state: state)
            var nextToken = self.sampler.sample(logits: firstLogits)

            for _ in 0 ..< self.maxNewTokens {
                if nextToken == self.engine.eosTokenId { break }
                generated.append(nextToken)
                let logits = try self.engine.runStep(token: nextToken, state: state)
                nextToken = self.sampler.sample(logits: logits)
            }

            return self.tokenizer.decode(tokens: generated)
        }.value
    }

    /// Streaming generation. Yields each decoded token chunk via `AsyncThrowingStream`.
    func generateStream(promptTokens: [Int]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let state = self.engine.makeConversationState()

                    guard !promptTokens.isEmpty else {
                        throw CoreMLBackendError.generationFailed(reason: "prompt tokens are empty")
                    }
                    for token in promptTokens {
                        _ = try self.engine.runStep(token: token, state: state)
                    }

                    let firstLogits = try self.engine.runStep(token: promptTokens.last!, state: state)
                    var nextToken = self.sampler.sample(logits: firstLogits)

                    for _ in 0 ..< self.maxNewTokens {
                        if nextToken == self.engine.eosTokenId { break }
                        let chunk = self.tokenizer.decode(token: nextToken)
                        continuation.yield(chunk)
                        let logits = try self.engine.runStep(token: nextToken, state: state)
                        nextToken = self.sampler.sample(logits: logits)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
