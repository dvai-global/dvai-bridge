// @vitest-environment happy-dom
import { describe, it, expect, vi } from "vitest";
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

describe("HttpTransport (lightweight smoke)", () => {
  it("reports kind=http", async () => {
    const { HttpTransport } = await import("../transports/http");
    const t = new HttpTransport({
      httpBasePort: 39100,
      httpMaxPortAttempts: 1,
      corsOrigin: "*",
    });
    expect(t.kind).toBe("http");
  });
});

describe("selectTransport", () => {
  it("returns explicit value unchanged when not auto", async () => {
    const { selectTransport } = await import("../transports/index");
    expect(selectTransport({ transport: "http" })).toBe("http");
    expect(selectTransport({ transport: "msw" })).toBe("msw");
    expect(selectTransport({ transport: "none" })).toBe("none");
  });

  it("preserves serviceWorkerUrl:'' back-compat escape hatch", async () => {
    const { selectTransport } = await import("../transports/index");
    expect(selectTransport({ serviceWorkerUrl: "" })).toBe("none");
  });

  it("explicit transport wins over empty serviceWorkerUrl", async () => {
    const { selectTransport } = await import("../transports/index");
    expect(selectTransport({ transport: "msw", serviceWorkerUrl: "" })).toBe("msw");
  });

  it("resolves auto to msw when browser globals (incl. serviceWorker) are present", async () => {
    const { selectTransport } = await import("../transports/index");
    // happy-dom provides window/document/navigator but not a serviceWorker
    // registration surface, so stub the one field isBrowserLike() looks at.
    const nav = globalThis.navigator as any;
    const hadSw = "serviceWorker" in nav;
    const prev = nav.serviceWorker;
    if (!hadSw) nav.serviceWorker = { register: () => {} };
    try {
      expect(selectTransport({ transport: "auto" })).toBe("msw");
    } finally {
      if (hadSw) nav.serviceWorker = prev;
      else delete nav.serviceWorker;
    }
  });
});

describe("CapacitorTransport", () => {
  it("kind is 'capacitor'", async () => {
    const { CapacitorTransport } = await import("../transports/capacitor");
    const t = new CapacitorTransport({
      capacitorBackend: "llama",
      nativeModelPath: "/m.gguf",
      httpBasePort: 38883,
      httpMaxPortAttempts: 16,
      corsOrigin: "*",
    });
    expect(t.kind).toBe("capacitor");
  });

  it("start() calls DVAIBridge.start with backend + modelPath", async () => {
    vi.doMock("@dvai-bridge/capacitor", () => ({
      DVAIBridge: {
        start: vi.fn(async (opts: any) => ({
          baseUrl: "http://127.0.0.1:38883/v1",
          port: 38883,
          backend: opts.backend,
          modelId: opts.modelPath,
        })),
        stop: vi.fn(async () => undefined),
      },
    }));

    const { CapacitorTransport } = await import("../transports/capacitor");
    const t = new CapacitorTransport({
      capacitorBackend: "llama",
      nativeModelPath: "/test.gguf",
      httpBasePort: 38883,
      httpMaxPortAttempts: 16,
      corsOrigin: "*",
    });
    const result = await t.start({} as any);
    expect(result).toEqual({ baseUrl: "http://127.0.0.1:38883/v1", port: 38883 });
  });
});
