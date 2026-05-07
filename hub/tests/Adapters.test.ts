import { describe, it, expect, vi } from "vitest";
import { parseModelName } from "../peer-mode/ModelParser.js";
import {
  LMStudioAdapter,
  parseLmsListOutput,
} from "../peer-mode/adapters/LMStudioAdapter.js";
import { VLLMAdapter } from "../peer-mode/adapters/VLLMAdapter.js";
import { LlamaServerAdapter } from "../peer-mode/adapters/LlamaServerAdapter.js";
import { LlamafileAdapter } from "../peer-mode/adapters/LlamafileAdapter.js";
import type { ChatRequest } from "../peer-mode/EngineBridge.js";

/* -------------------------------------------------------------------------- */
/* LMStudioAdapter                                                            */
/* -------------------------------------------------------------------------- */

describe("LMStudioAdapter", () => {
  it("detects via /v1/models", async () => {
    const fetchImpl = vi.fn(async () => new Response("{}", { status: 200 }));
    const adapter = new LMStudioAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    expect(await adapter.detect()).toBe(true);
    expect(fetchImpl).toHaveBeenCalledWith(
      expect.stringContaining("/v1/models"),
      expect.objectContaining({ method: "GET" }),
    );
  });

  it("enumerates from /v1/models payload", async () => {
    const payload = {
      data: [
        { id: "llama-3.2-3b-instruct-q4_k_m" },
        { id: "qwen2.5-coder-7b-instruct" },
      ],
    };
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify(payload), { status: 200 }));
    const adapter = new LMStudioAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    const out = await adapter.enumerateCachedModels();
    expect(out.length).toBe(2);
    expect(out[0]?.descriptor.family).toBe("llama");
    expect(out[1]?.descriptor.type).toBe("code");
  });

  it("serves through /v1/chat/completions on the configured base URL", async () => {
    const fetchImpl = vi.fn(async (url: string) => {
      expect(url).toBe("http://127.0.0.1:1234/v1/chat/completions");
      return new Response(JSON.stringify({ id: "ok" }), { status: 200 });
    });
    const adapter = new LMStudioAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    const req: ChatRequest = {
      model: "llama-3.2-3b-instruct",
      messages: [{ role: "user", content: "Hi" }],
    };
    const res = await adapter.serveRequest(parseModelName(req.model), req);
    expect(res.status).toBe(200);
  });

  it("parseLmsListOutput skips the header row", () => {
    const stdout =
      "MODEL                       SIZE\n" +
      "llama-3.2-3b-instruct-q4    1.7 GB\n" +
      "gemma-2-2b-it-q8            2.1 GB\n";
    const out = parseLmsListOutput(stdout, "lmstudio");
    expect(out.length).toBe(2);
    expect(out[0]?.engineModelId).toBe("llama-3.2-3b-instruct-q4");
  });
});

/* -------------------------------------------------------------------------- */
/* VLLMAdapter                                                                */
/* -------------------------------------------------------------------------- */

describe("VLLMAdapter", () => {
  it("detects via /v1/models", async () => {
    const fetchImpl = vi.fn(async () => new Response("{}", { status: 200 }));
    const adapter = new VLLMAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    expect(await adapter.detect()).toBe(true);
  });

  it("enumerates the single advertised model", async () => {
    const payload = {
      data: [{ id: "meta-llama/Llama-3.2-3B-Instruct" }],
    };
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify(payload), { status: 200 }));
    const adapter = new VLLMAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    const out = await adapter.enumerateCachedModels();
    expect(out.length).toBe(1);
    expect(out[0]?.descriptor.family).toBe("llama");
    expect(out[0]?.descriptor.size).toBe("3b");
  });

  it("returns [] on detection error", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error("network down");
    });
    const adapter = new VLLMAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    expect(await adapter.detect()).toBe(false);
  });
});

/* -------------------------------------------------------------------------- */
/* LlamaServerAdapter                                                         */
/* -------------------------------------------------------------------------- */

describe("LlamaServerAdapter", () => {
  it("detects via /v1/models on port 8080 by default", async () => {
    const fetchImpl = vi.fn(async (url: string) => {
      expect(url).toBe("http://127.0.0.1:8080/v1/models");
      return new Response("{}", { status: 200 });
    });
    const adapter = new LlamaServerAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    expect(await adapter.detect()).toBe(true);
  });

  it("enumerates and parses the model id", async () => {
    const payload = { data: [{ id: "Llama-3.2-3B-Instruct-Q4_K_M.gguf" }] };
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify(payload), { status: 200 }));
    const adapter = new LlamaServerAdapter({ fetchImpl: fetchImpl as unknown as typeof fetch });
    const out = await adapter.enumerateCachedModels();
    expect(out.length).toBe(1);
    expect(out[0]?.descriptor.size).toBe("3b");
  });
});

/* -------------------------------------------------------------------------- */
/* LlamafileAdapter                                                           */
/* -------------------------------------------------------------------------- */

describe("LlamafileAdapter", () => {
  it("detects when at least one *.llamafile is present", async () => {
    const fsImpl = {
      readdir: async () => ["llava-v1.5-7b-q4.llamafile", "README.txt"],
    };
    const adapter = new LlamafileAdapter({ fsImpl });
    expect(await adapter.detect()).toBe(true);
  });

  it("doesn't detect when the dir is empty / missing", async () => {
    const fsImpl = {
      readdir: async () => {
        throw new Error("ENOENT");
      },
    };
    const adapter = new LlamafileAdapter({ fsImpl });
    expect(await adapter.detect()).toBe(false);
  });

  it("enumerates *.llamafile + *.llamafile.exe as descriptors", async () => {
    const fsImpl = {
      readdir: async () => [
        "llava-v1.5-7b-q4.llamafile",
        "llama-3.2-3b-instruct-q4_k_m.llamafile.exe",
        "README.txt",
        "llamafile-config.json",
      ],
    };
    const adapter = new LlamafileAdapter({ fsImpl });
    const out = await adapter.enumerateCachedModels();
    expect(out.length).toBe(2);
    expect(out[0]?.descriptor.size).toBe("7b");
    expect(out[1]?.descriptor.quant).toBe("q4_k_m");
  });

  it("serveRequest returns 503 when no runningBaseUrl is configured", async () => {
    const adapter = new LlamafileAdapter({});
    const req: ChatRequest = { model: "x", messages: [] };
    const res = await adapter.serveRequest(parseModelName("x"), req);
    expect(res.status).toBe(503);
    const body = res.body as { error?: { type?: string } };
    expect(body.error?.type).toBe("llamafile_not_running");
  });

  it("serveRequest forwards to runningBaseUrl when configured", async () => {
    const fetchImpl = vi.fn(async (url: string) => {
      expect(url).toBe("http://127.0.0.1:9999/v1/chat/completions");
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    });
    const adapter = new LlamafileAdapter({
      runningBaseUrl: "http://127.0.0.1:9999",
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    const req: ChatRequest = { model: "x", messages: [] };
    const res = await adapter.serveRequest(parseModelName("x"), req);
    expect(res.status).toBe(200);
  });
});
