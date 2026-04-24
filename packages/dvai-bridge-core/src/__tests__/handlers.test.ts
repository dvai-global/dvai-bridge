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
