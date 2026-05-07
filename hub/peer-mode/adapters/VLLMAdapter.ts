/**
 * Phase 4 — vLLM EngineAdapter.
 *
 * vLLM is a single-model server — its OpenAI-compat surface advertises
 * exactly one model (whatever was launched on `--model <id>`). The
 * adapter detects via `GET /v1/models` and treats the first row as
 * the cached catalog. There is no subprocess enumeration path; vLLM's
 * model is fixed at launch time.
 */

import { parseModelName } from "../ModelParser.js";
import type {
  ChatRequest,
  ChatResponse,
  EngineAdapter,
  StreamResponse,
} from "../EngineBridge.js";
import type { BackendDescriptor } from "../SubstitutionPolicy.js";

const DEFAULT_BASE_URL = "http://127.0.0.1:8000";
const DETECT_TIMEOUT_MS = 1500;

export interface VLLMAdapterOptions {
  baseUrl?: string;
  fetchImpl?: typeof fetch;
}

interface OpenAIModelsResponse {
  data?: Array<{ id?: string }>;
}

export class VLLMAdapter implements EngineAdapter {
  readonly name = "vllm";
  private readonly baseUrl: string;
  private readonly fetchImpl: typeof fetch;

  constructor(opts: VLLMAdapterOptions = {}) {
    this.baseUrl = opts.baseUrl ?? DEFAULT_BASE_URL;
    this.fetchImpl = opts.fetchImpl ?? globalThis.fetch;
  }

  async detect(): Promise<boolean> {
    try {
      const res = await this.timed(`${this.baseUrl}/v1/models`, { method: "GET" }, DETECT_TIMEOUT_MS);
      return res.ok;
    } catch {
      return false;
    }
  }

  async enumerateCachedModels(): Promise<BackendDescriptor[]> {
    const res = await this.timed(`${this.baseUrl}/v1/models`, { method: "GET" }, DETECT_TIMEOUT_MS * 2);
    if (!res.ok) return [];
    const json = (await res.json().catch(() => null)) as OpenAIModelsResponse | null;
    if (!json?.data) return [];
    return json.data
      .map((m): BackendDescriptor | null => {
        if (!m.id) return null;
        return { descriptor: parseModelName(m.id), engine: this.name, engineModelId: m.id };
      })
      .filter((b): b is BackendDescriptor => b !== null);
  }

  async serveRequest(
    _descriptor: import("../ModelParser.js").ModelDescriptor,
    request: ChatRequest,
  ): Promise<ChatResponse | StreamResponse> {
    const url = `${this.baseUrl}/v1/chat/completions`;
    const res = await this.fetchImpl(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(request),
    });
    const headers = headersToObject(res.headers);
    if (request.stream === true && res.body !== null) {
      return { status: res.status, headers, body: streamFromBody(res.body) };
    }
    const body = (await res.json().catch(() => null)) as unknown;
    return { status: res.status, headers, body };
  }

  async close(): Promise<void> {
    /* no persistent state */
  }

  private async timed(url: string, init: RequestInit, ms: number): Promise<Response> {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), ms);
    try {
      return await this.fetchImpl(url, { ...init, signal: ctrl.signal });
    } finally {
      clearTimeout(t);
    }
  }
}

function headersToObject(h: Headers): Record<string, string> {
  const out: Record<string, string> = {};
  h.forEach((v, k) => {
    out[k] = v;
  });
  return out;
}

async function* streamFromBody(body: ReadableStream<Uint8Array>): AsyncIterable<Uint8Array> {
  const reader = body.getReader();
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) return;
      if (value) yield value;
    }
  } finally {
    reader.releaseLock();
  }
}
