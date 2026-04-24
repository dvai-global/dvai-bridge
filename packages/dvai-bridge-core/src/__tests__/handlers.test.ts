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
