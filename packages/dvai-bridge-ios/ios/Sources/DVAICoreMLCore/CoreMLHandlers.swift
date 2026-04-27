import Foundation
#if !COCOAPODS
import DVAISharedCore
#endif

/// `DVAIHandlers` conformer for the CoreML backend.
/// Translates OpenAI-compatible HTTP requests into CoreMLGenerator calls and
/// formats the results as OpenAI JSON / SSE responses.
@available(iOS 18.0, macOS 15.0, *)
public final class CoreMLHandlers: DVAIHandlers {
    private let generator: CoreMLGenerator
    private let modelId: String

    // Internal init — `CoreMLGenerator` is an implementation detail of
    // DVAICoreMLCore and stays internal. The only construction site is
    // `CoreMLPluginState.start()` inside the same module.
    internal init(generator: CoreMLGenerator, modelId: String) {
        self.generator = generator
        self.modelId = modelId
    }

    public func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        guard let messages = body["messages"] as? [[String: String]] else {
            return .error(400, "messages array is required")
        }
        let stream = (body["stream"] as? Bool) ?? false
        let temperature = (body["temperature"] as? Double).map(Float.init) ?? 0.0
        let topP = (body["top_p"] as? Double).map(Float.init) ?? 1.0
        let maxTokens = (body["max_tokens"] as? Int) ?? 512

        // Build a generator with the per-request sampling params.
        let requestSampler = CoreMLSampler(temperature: temperature, topP: topP, topK: 0)
        let requestGenerator = CoreMLGenerator(
            engine: generator.engine,
            tokenizer: generator.tokenizer,
            sampler: requestSampler,
            maxNewTokens: maxTokens
        )

        let promptTokens: [Int]
        do {
            promptTokens = try generator.tokenizer.applyChatTemplate(messages: messages)
        } catch {
            return .error(400, "tokenizer chat-template failed: \(error.localizedDescription)")
        }

        if stream {
            let sse = requestGenerator.generateStream(promptTokens: promptTokens)
            let streamId = UUID().uuidString
            let mappedStream = AsyncStream<String> { cont in
                Task {
                    do {
                        for try await chunk in sse {
                            let evt = "data: {\"id\":\"\(streamId)\",\"object\":\"chat.completion.chunk\",\"created\":\(Int(Date().timeIntervalSince1970)),\"model\":\"\(modelId)\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\(jsonString(chunk))},\"finish_reason\":null}]}\n\n"
                            cont.yield(evt)
                        }
                        cont.yield("data: [DONE]\n\n")
                        cont.finish()
                    } catch {
                        cont.yield("data: {\"error\":\"\(error.localizedDescription)\"}\n\n")
                        cont.finish()
                    }
                }
            }
            return .sse(mappedStream)
        }

        let text: String
        do {
            text = try await requestGenerator.generate(promptTokens: promptTokens)
        } catch {
            return .error(500, "generation failed: \(error.localizedDescription)")
        }
        let responseJSON: [String: Any] = [
            "id": UUID().uuidString,
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": modelId,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": text],
                "finish_reason": "stop"
            ]],
            "usage": [
                "prompt_tokens": promptTokens.count,
                "completion_tokens": -1,  // CoreML decoding doesn't track this per checkpoint
                "total_tokens": -1
            ]
        ]
        return .json(200, responseJSON)
    }

    public func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        let prompt = body["prompt"] as? String ?? ""
        let chatBody: [String: Any] = [
            "messages": [["role": "user", "content": prompt]],
            "stream": body["stream"] as? Bool ?? false,
            "temperature": body["temperature"] as? Double ?? 0.0,
            "top_p": body["top_p"] as? Double ?? 1.0,
            "max_tokens": body["max_tokens"] as? Int ?? 512,
        ]
        return try await handleChatCompletion(body: chatBody, ctx: ctx)
    }

    public func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .error(501, "embeddings not yet supported by the CoreML backend")
    }

    public func handleModels(ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(200, [
            "object": "list",
            "data": [["id": modelId, "object": "model", "owned_by": "dvai-bridge"]]
        ])
    }

    /// JSON-encode a single string value (produces a quoted JSON string).
    private func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data()
        let str = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // Strip the surrounding array brackets — leaves the quoted string value.
        return String(str.dropFirst().dropLast())
    }
}
