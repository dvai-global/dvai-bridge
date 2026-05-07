import { describe, it, expect, vi } from "vitest";
import { parseModelName } from "../peer-mode/ModelParser.js";
import {
  EngineBridge,
  type ChatRequest,
  type ChatResponse,
  type EngineAdapter,
  type StreamResponse,
} from "../peer-mode/EngineBridge.js";
import {
  OllamaAdapter,
  parseOllamaListOutput,
} from "../peer-mode/adapters/OllamaAdapter.js";
import type { BackendDescriptor } from "../peer-mode/SubstitutionPolicy.js";

/** Build a fake adapter with controllable behaviour. */
function fakeAdapter(opts: {
  name: string;
  detect?: () => Promise<boolean>;
  enumerate?: () => Promise<BackendDescriptor[]>;
  serve?: (req: ChatRequest) => Promise<ChatResponse | StreamResponse>;
  close?: () => Promise<void>;
}): EngineAdapter {
  return {
    name: opts.name,
    detect: opts.detect ?? (async () => true),
    enumerateCachedModels: opts.enumerate ?? (async () => []),
    serveRequest: async (_d, req) =>
      (opts.serve ?? (async () => ({
        status: 200,
        headers: {},
        body: { ok: true },
      })))(req),
    close: opts.close ?? (async () => undefined),
  };
}

function backend(modelString: string, engine = "fake"): BackendDescriptor {
  return {
    descriptor: parseModelName(modelString),
    engine,
    engineModelId: modelString,
  };
}

describe("EngineBridge — lifecycle", () => {
  it("does not enumerate when disabled", async () => {
    const enumerate = vi.fn(async () => [backend("Llama-3.2-3B-Instruct-Q4_K_M")]);
    const bridge = new EngineBridge({
      enabled: false,
      adapters: [fakeAdapter({ name: "x", enumerate })],
    });
    await bridge.start();
    expect(enumerate).not.toHaveBeenCalled();
    expect(await bridge.enumerateAvailable()).toEqual([]);
  });

  it("enumerates each detected adapter once at start()", async () => {
    const enumerate = vi.fn(async () => [backend("Llama-3.2-3B-Instruct-Q4_K_M", "x")]);
    const bridge = new EngineBridge({
      enabled: true,
      adapters: [fakeAdapter({ name: "x", enumerate })],
    });
    await bridge.start();
    expect(enumerate).toHaveBeenCalledTimes(1);
    const detected = bridge.detected();
    expect(detected).toEqual([
      expect.objectContaining({ name: "x", detected: true, modelCount: 1 }),
    ]);
  });

  it("skips enumeration when detect() returns false", async () => {
    const enumerate = vi.fn(async () => []);
    const bridge = new EngineBridge({
      enabled: true,
      adapters: [
        fakeAdapter({ name: "off", detect: async () => false, enumerate }),
      ],
    });
    await bridge.start();
    expect(enumerate).not.toHaveBeenCalled();
    expect(bridge.detected()[0]?.detected).toBe(false);
  });

  it("isolates a failing adapter from healthy adapters", async () => {
    const bridge = new EngineBridge({
      enabled: true,
      adapters: [
        fakeAdapter({
          name: "broken",
          detect: async () => {
            throw new Error("boom");
          },
        }),
        fakeAdapter({
          name: "ok",
          enumerate: async () => [backend("Llama-3.2-3B-Instruct-Q4_K_M", "ok")],
        }),
      ],
    });
    await bridge.start();
    const summary = bridge.detected();
    expect(summary.find((s) => s.name === "broken")?.detected).toBe(false);
    expect(summary.find((s) => s.name === "ok")?.detected).toBe(true);
    const all = await bridge.enumerateAvailable();
    expect(all.length).toBe(1);
    expect(all[0]?.engine).toBe("ok");
  });

  it("calls close() on every adapter at stop()", async () => {
    const closeA = vi.fn(async () => undefined);
    const closeB = vi.fn(async () => undefined);
    const bridge = new EngineBridge({
      enabled: true,
      adapters: [
        fakeAdapter({ name: "a", close: closeA }),
        fakeAdapter({ name: "b", close: closeB }),
      ],
    });
    await bridge.start();
    await bridge.stop();
    expect(closeA).toHaveBeenCalledTimes(1);
    expect(closeB).toHaveBeenCalledTimes(1);
  });
});

describe("EngineBridge — caching + invalidation", () => {
  it("does not re-enumerate within TTL", async () => {
    const enumerate = vi.fn(async () => [backend("Llama-3.2-3B-Instruct-Q4_K_M", "x")]);
    const bridge = new EngineBridge({
      enabled: true,
      adapters: [fakeAdapter({ name: "x", enumerate })],
      cacheTtlMs: 60_000,
    });
    await bridge.start();
    await bridge.enumerateAvailable();
    await bridge.enumerateAvailable();
    expect(enumerate).toHaveBeenCalledTimes(1);
  });

  it("re-enumerates after invalidateCache(name)", async () => {
    const enumerate = vi.fn(async () => [backend("Llama-3.2-3B-Instruct-Q4_K_M", "x")]);
    const bridge = new EngineBridge({
      enabled: true,
      adapters: [fakeAdapter({ name: "x", enumerate })],
      cacheTtlMs: 60_000,
    });
    await bridge.start();
    await bridge.invalidateCache("x");
    await bridge.enumerateAvailable();
    expect(enumerate).toHaveBeenCalledTimes(2);
  });

  it("invalidateCache() with no name clears all entries", async () => {
    const eA = vi.fn(async () => [backend("Llama-3.2-3B-Instruct-Q4_K_M", "a")]);
    const eB = vi.fn(async () => [backend("Llama-3.2-1B-Instruct-Q4_K_M", "b")]);
    const bridge = new EngineBridge({
      enabled: true,
      adapters: [
        fakeAdapter({ name: "a", enumerate: eA }),
        fakeAdapter({ name: "b", enumerate: eB }),
      ],
      cacheTtlMs: 60_000,
    });
    await bridge.start();
    await bridge.invalidateCache();
    await bridge.enumerateAvailable();
    expect(eA).toHaveBeenCalledTimes(2);
    expect(eB).toHaveBeenCalledTimes(2);
  });

  it("findAdapter returns the matching adapter or undefined", async () => {
    const a = fakeAdapter({ name: "alpha" });
    const b = fakeAdapter({ name: "beta" });
    const bridge = new EngineBridge({ enabled: true, adapters: [a, b] });
    expect(bridge.findAdapter("alpha")).toBe(a);
    expect(bridge.findAdapter("beta")).toBe(b);
    expect(bridge.findAdapter("missing")).toBeUndefined();
  });
});

describe("OllamaAdapter — `ollama ls` output parsing", () => {
  it("parses table output with header row, ignoring it", () => {
    const stdout =
      "NAME                ID              SIZE      MODIFIED\n" +
      "llama3.2:1b         abc123          1.3 GB    3 days ago\n" +
      "gemma:2b            def456          1.7 GB    1 week ago\n";
    const out = parseOllamaListOutput(stdout, "ollama");
    expect(out.length).toBe(2);
    expect(out[0]?.engineModelId).toBe("llama3.2:1b");
    expect(out[0]?.descriptor.family).toBe("llama");
    expect(out[1]?.engineModelId).toBe("gemma:2b");
    expect(out[1]?.descriptor.size).toBe("2b");
  });

  it("ignores blank lines and whitespace", () => {
    const stdout = "\n\nllama3.2:1b   abc123\n\n\n";
    const out = parseOllamaListOutput(stdout, "ollama");
    expect(out.length).toBe(1);
    expect(out[0]?.engineModelId).toBe("llama3.2:1b");
  });
});

describe("OllamaAdapter — HTTP detect + enumerate", () => {
  it("detect() returns true when /api/tags responds OK", async () => {
    const fetchImpl = vi.fn(async () => new Response("{}", { status: 200 }));
    const adapter = new OllamaAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    expect(await adapter.detect()).toBe(true);
  });

  it("detect() returns false when /api/tags errors", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error("ECONNREFUSED");
    });
    const adapter = new OllamaAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    expect(await adapter.detect()).toBe(false);
  });

  it("enumerateCachedModels() parses /api/tags JSON into descriptors", async () => {
    const tags = {
      models: [
        { name: "llama3.2:1b" },
        { name: "gemma:2b" },
        { name: "qwen2.5-coder:7b" },
      ],
    };
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify(tags), { status: 200 }));
    const adapter = new OllamaAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    const out = await adapter.enumerateCachedModels();
    expect(out.length).toBe(3);
    expect(out.map((b) => b.engineModelId)).toEqual([
      "llama3.2:1b",
      "gemma:2b",
      "qwen2.5-coder:7b",
    ]);
    expect(out[0]?.descriptor.family).toBe("llama");
    expect(out[2]?.descriptor.type).toBe("code");
  });

  it("enumerateCachedModels() returns [] when /api/tags is malformed", async () => {
    const fetchImpl = vi.fn(async () => new Response("not json", { status: 200 }));
    const adapter = new OllamaAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    const out = await adapter.enumerateCachedModels();
    expect(out).toEqual([]);
  });

  it("serveRequest() proxies to /v1/chat/completions on the configured baseUrl", async () => {
    const fetchImpl = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://127.0.0.1:11434/v1/chat/completions");
      expect(init.method).toBe("POST");
      return new Response(JSON.stringify({ id: "abc" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    const adapter = new OllamaAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    const req: ChatRequest = {
      model: "llama3.2:1b",
      messages: [{ role: "user", content: "Hi" }],
    };
    const desc = parseModelName("llama3.2:1b");
    const res = await adapter.serveRequest(desc, req);
    expect(res.status).toBe(200);
    expect((res.body as { id?: string }).id).toBe("abc");
  });
});
