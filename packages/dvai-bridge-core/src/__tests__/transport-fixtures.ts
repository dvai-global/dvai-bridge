import type { BackendInterface, HandlerContext } from "../handlers/context";

export const CANNED_CHAT_COMPLETION = {
  id: "chatcmpl-fixed",
  object: "chat.completion",
  created: 1700000000,
  model: "test-model",
  choices: [
    {
      index: 0,
      message: { role: "assistant", content: "canned" },
      finish_reason: "stop",
    },
  ],
  usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
};

export function makeStreamBackend(): BackendInterface {
  return {
    chatCompletion: async () => CANNED_CHAT_COMPLETION,
    createStreamingResponse: () => {
      const encoder = new TextEncoder();
      return new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(
            encoder.encode(
              `data: ${JSON.stringify({ id: "chatcmpl-fixed", choices: [{ delta: { content: "canned" }, index: 0 }] })}\n\n`,
            ),
          );
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        },
      });
    },
    embedding: async (inputs) => {
      const arr = Array.isArray(inputs) ? inputs : [inputs];
      return arr.map((_, i) => [i * 0.1, i * 0.2, i * 0.3]);
    },
  };
}

export function makeCtx(
  backend: BackendInterface = makeStreamBackend(),
  overrides: Partial<HandlerContext> = {},
): HandlerContext {
  return {
    backend,
    resolvedBackend: "transformers",
    modelId: "test-model",
    ...overrides,
  };
}

export const CHAT_REQUEST = {
  model: "test-model",
  messages: [{ role: "user", content: "hi" }],
};

export const COMPLETION_REQUEST = {
  model: "test-model",
  prompt: "hi",
};

export const EMBEDDING_REQUEST = {
  model: "test-model",
  input: ["hello", "world"],
};
