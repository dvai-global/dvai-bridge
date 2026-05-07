/**
 * Phase 4 — LM Studio EngineAdapter.
 *
 * LM Studio runs a local OpenAI-compatible server on `localhost:1234`
 * (configurable). Unlike Ollama, LM Studio's enumeration surface is
 * the standard `GET /v1/models` (it speaks OpenAI). The
 * `lms ls` subprocess is also exposed for parity with `ollama ls`.
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { parseModelName } from "../ModelParser.js";
import type {
  ChatRequest,
  ChatResponse,
  EngineAdapter,
  StreamResponse,
} from "../EngineBridge.js";
import type { BackendDescriptor } from "../SubstitutionPolicy.js";

const execFileAsync = promisify(execFile);

const DEFAULT_BASE_URL = "http://127.0.0.1:1234";
const DETECT_TIMEOUT_MS = 1500;
const SUBPROCESS_TIMEOUT_MS = 8000;

export interface LMStudioAdapterOptions {
  baseUrl?: string;
  useSubprocessEnumeration?: boolean;
  fetchImpl?: typeof fetch;
}

interface OpenAIModelsResponse {
  data?: Array<{ id?: string }>;
}

export class LMStudioAdapter implements EngineAdapter {
  readonly name = "lmstudio";
  private readonly baseUrl: string;
  private readonly useSubprocess: boolean;
  private readonly fetchImpl: typeof fetch;

  constructor(opts: LMStudioAdapterOptions = {}) {
    this.baseUrl = opts.baseUrl ?? DEFAULT_BASE_URL;
    this.useSubprocess = opts.useSubprocessEnumeration ?? false;
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
    if (this.useSubprocess) return this.enumerateViaSubprocess();
    return this.enumerateViaApi();
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

  private async enumerateViaApi(): Promise<BackendDescriptor[]> {
    const res = await this.timed(`${this.baseUrl}/v1/models`, { method: "GET" }, DETECT_TIMEOUT_MS * 2);
    if (!res.ok) return [];
    const json = (await res.json().catch(() => null)) as OpenAIModelsResponse | null;
    if (!json?.data) return [];
    return json.data
      .map((m): BackendDescriptor | null => {
        if (!m.id) return null;
        return {
          descriptor: parseModelName(m.id),
          engine: this.name,
          engineModelId: m.id,
        };
      })
      .filter((b): b is BackendDescriptor => b !== null);
  }

  private async enumerateViaSubprocess(): Promise<BackendDescriptor[]> {
    try {
      const { stdout } = await execFileAsync("lms", ["ls"], {
        timeout: SUBPROCESS_TIMEOUT_MS,
        windowsHide: true,
      });
      return parseLmsListOutput(stdout, this.name);
    } catch {
      return [];
    }
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

/**
 * Parse `lms ls` output. The format includes a header row and tab/space-
 * separated columns; first non-header column is the model id.
 */
export function parseLmsListOutput(
  stdout: string,
  engineName: string,
): BackendDescriptor[] {
  const lines = stdout.split(/\r?\n/);
  const out: BackendDescriptor[] = [];
  for (const line of lines) {
    if (!line.trim()) continue;
    if (/^\s*(MODEL|NAME|PATH)\b/i.test(line)) continue;
    const m = /^\s*(\S+)/.exec(line);
    if (!m) continue;
    const id = m[1]!;
    out.push({ descriptor: parseModelName(id), engine: engineName, engineModelId: id });
  }
  return out;
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
