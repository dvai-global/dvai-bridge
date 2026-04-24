import { describe, it, expect } from "vitest";
import type { BackendInterface, HandlerContext } from "../handlers/context";

const fakeBackend: BackendInterface = {
  chatCompletion: async () => ({}),
  createStreamingResponse: () => new ReadableStream<Uint8Array>(),
};

function makeCtx(overrides: Partial<HandlerContext> = {}): HandlerContext {
  return {
    backend: fakeBackend,
    resolvedBackend: "webllm",
    modelId: "test-model",
    ...overrides,
  };
}

describe("handleModels", () => {
  it("returns an OpenAI-shaped list with the context model id", async () => {
    const { handleModels } = await import("../handlers/models");
    const res = await handleModels(makeCtx({ modelId: "gemma-2-2b-it-q4f16_1-MLC" }));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.object).toBe("list");
    expect(body.data).toHaveLength(1);
    expect(body.data[0]).toMatchObject({
      id: "gemma-2-2b-it-q4f16_1-MLC",
      object: "model",
      owned_by: "dvai-bridge",
    });
    expect(typeof body.data[0].created).toBe("number");
  });

  it("echoes whatever modelId the context provides", async () => {
    const { handleModels } = await import("../handlers/models");
    const res = await handleModels(makeCtx({ modelId: "custom-x" }));
    const body = await res.json();
    expect(body.data[0].id).toBe("custom-x");
  });
});

describe("handleEmbeddings", () => {
  const embeddingBackend: BackendInterface = {
    ...fakeBackend,
    embedding: async (inputs) => {
      const arr = Array.isArray(inputs) ? inputs : [inputs];
      return arr.map((_, i) => [i, i + 0.1, i + 0.2]);
    },
  };

  it("returns 503 when backend is null", async () => {
    const { handleEmbeddings } = await import("../handlers/embeddings");
    const res = await handleEmbeddings({ input: "hi" }, makeCtx({ backend: null }));
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "AI engine not initialized" });
  });

  it("returns 400 on webllm backend (unsupported)", async () => {
    const { handleEmbeddings } = await import("../handlers/embeddings");
    const res = await handleEmbeddings(
      { input: "hi" },
      makeCtx({ backend: embeddingBackend, resolvedBackend: "webllm" }),
    );
    expect(res.status).toBe(400);
    expect((await res.json()).error).toMatch(/not supported on the WebLLM backend/);
  });

  it("returns 400 when backend lacks embedding()", async () => {
    const { handleEmbeddings } = await import("../handlers/embeddings");
    const res = await handleEmbeddings(
      { input: "hi" },
      makeCtx({ backend: fakeBackend, resolvedBackend: "transformers" }),
    );
    expect(res.status).toBe(400);
    expect((await res.json()).error).toMatch(/does not support embeddings/);
  });

  it("returns 400 when input is missing", async () => {
    const { handleEmbeddings } = await import("../handlers/embeddings");
    const res = await handleEmbeddings(
      {},
      makeCtx({ backend: embeddingBackend, resolvedBackend: "transformers" }),
    );
    expect(res.status).toBe(400);
    expect((await res.json()).error).toMatch(/Missing 'input' field/);
  });

  it("returns OpenAI-shaped embeddings list on success", async () => {
    const { handleEmbeddings } = await import("../handlers/embeddings");
    const res = await handleEmbeddings(
      { input: ["hello", "world"] },
      makeCtx({ backend: embeddingBackend, resolvedBackend: "transformers", modelId: "mm" }),
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.object).toBe("list");
    expect(body.model).toBe("mm");
    expect(body.data).toHaveLength(2);
    expect(body.data[0]).toMatchObject({ object: "embedding", index: 0 });
    expect(body.data[0].embedding).toEqual([0, 0.1, 0.2]);
  });
});

describe("handleCompletion (legacy)", () => {
  const canned = {
    id: "chatcmpl-abc",
    object: "chat.completion",
    created: 1700000000,
    model: "m",
    choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
  };
  const completionBackend: BackendInterface = {
    chatCompletion: async () => canned,
    createStreamingResponse: () => new ReadableStream<Uint8Array>(),
  };

  it("returns 503 when backend is null", async () => {
    const { handleCompletion } = await import("../handlers/completions");
    const res = await handleCompletion({ prompt: "x" }, makeCtx({ backend: null }));
    expect(res.status).toBe(503);
  });

  it("converts prompt to messages, returns text_completion shape", async () => {
    const { handleCompletion } = await import("../handlers/completions");
    const res = await handleCompletion(
      { prompt: "hi", model: "m" },
      makeCtx({ backend: completionBackend, modelId: "m" }),
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.object).toBe("text_completion");
    expect(body.id).toBe("cmpl-abc");
    expect(body.choices[0].text).toBe("hi");
  });

  it("joins prompt arrays with newlines", async () => {
    const { handleCompletion } = await import("../handlers/completions");
    let capturedBody: any;
    const capturing: BackendInterface = {
      ...completionBackend,
      chatCompletion: async (body) => { capturedBody = body; return canned; },
    };
    await handleCompletion(
      { prompt: ["line1", "line2"], model: "m" },
      makeCtx({ backend: capturing }),
    );
    expect(capturedBody.messages[0].content).toBe("line1\nline2");
    expect("prompt" in capturedBody).toBe(false);
  });
});

describe("legacy helpers (re-exported from completions)", () => {
  it("chatToLegacyCompletion converts basic shape", async () => {
    const { chatToLegacyCompletion } = await import("../handlers/completions");
    const out = chatToLegacyCompletion({
      id: "chatcmpl-1",
      created: 100,
      model: "m",
      choices: [{ index: 0, message: { content: "x" }, finish_reason: "stop" }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    });
    expect(out.object).toBe("text_completion");
    expect(out.id).toBe("cmpl-1");
    expect(out.choices[0].text).toBe("x");
  });
});

describe("handleChatCompletion", () => {
  const canned = {
    id: "chatcmpl-fixed",
    object: "chat.completion",
    created: 1700000000,
    model: "m",
    choices: [{ index: 0, message: { role: "assistant", content: "canned" }, finish_reason: "stop" }],
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
  };
  const chatBackend: BackendInterface = {
    chatCompletion: async () => canned,
    createStreamingResponse: () => {
      const encoder = new TextEncoder();
      return new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify({ id: "chatcmpl-fixed", choices: [{ delta: { content: "hi" }, index: 0 }] })}\n\n`));
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        },
      });
    },
  };

  it("returns 503 when backend is null", async () => {
    const { handleChatCompletion } = await import("../handlers/chat");
    const res = await handleChatCompletion({ messages: [] }, makeCtx({ backend: null }));
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "AI engine not initialized" });
  });

  it("returns the canned chat.completion on success (non-stream)", async () => {
    const { handleChatCompletion } = await import("../handlers/chat");
    const res = await handleChatCompletion(
      { messages: [{ role: "user", content: "hi" }] },
      makeCtx({ backend: chatBackend }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ id: "chatcmpl-fixed" });
  });

  it("returns SSE response with event-stream headers on stream=true", async () => {
    const { handleChatCompletion } = await import("../handlers/chat");
    const res = await handleChatCompletion(
      { stream: true, messages: [{ role: "user", content: "hi" }] },
      makeCtx({ backend: chatBackend }),
    );
    expect(res.headers.get("content-type")).toBe("text/event-stream");
    const text = await res.text();
    expect(text).toContain("data: [DONE]");
  });

  it("calls onRecovery when backend has lastFatalError pre-request", async () => {
    const { handleChatCompletion } = await import("../handlers/chat");
    const backendWithFatal: BackendInterface = {
      ...chatBackend,
      lastFatalError: "blank_output",
    };
    let recoveryCalls = 0;
    await handleChatCompletion(
      { messages: [{ role: "user", content: "hi" }] },
      makeCtx({
        backend: backendWithFatal,
        onRecovery: async () => { recoveryCalls++; },
      }),
    );
    expect(recoveryCalls).toBe(1);
  });

  it("returns 500 with error.message when backend throws and recovery fails", async () => {
    const { handleChatCompletion } = await import("../handlers/chat");
    const throwingBackend: BackendInterface = {
      ...chatBackend,
      chatCompletion: async () => { throw new Error("boom"); },
    };
    const res = await handleChatCompletion(
      { messages: [] },
      makeCtx({ backend: throwingBackend }),
    );
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: "boom" });
  });
});
