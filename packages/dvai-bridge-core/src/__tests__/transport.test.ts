// @vitest-environment happy-dom
import { describe, it, expect } from "vitest";
import type { HandlerContext, BackendInterface } from "../handlers/context";

const fakeBackend: BackendInterface = {
  chatCompletion: async () => ({ id: "x", choices: [] }),
  createStreamingResponse: () => new ReadableStream<Uint8Array>(),
};
const ctx: HandlerContext = {
  backend: fakeBackend,
  resolvedBackend: "webllm",
  modelId: "test",
};

describe("MswTransport", () => {
  it("reports kind=msw and returns a baseUrl derived from mockUrl", async () => {
    const { MswTransport } = await import("../transports/msw");
    const t = new MswTransport({
      mockUrl: "https://api.openai.local/v1/chat/completions",
      serviceWorkerUrl: "", // empty skips SW registration for this smoke test
    });
    expect(t.kind).toBe("msw");
    // start() with empty serviceWorkerUrl must not register a SW; baseUrl still derives
    const result = await t.start(ctx);
    expect(result.baseUrl).toBe("https://api.openai.local/v1");
    expect(result.port).toBeUndefined();
    await t.stop();
  });
});
