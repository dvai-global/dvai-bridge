/**
 * Phase 4 — Ollama EngineAdapter.
 *
 * Detects Ollama running locally (HTTP probe) and enumerates its
 * cached model catalog (HTTP /api/tags). For each cached model, parses
 * its name into a `ModelDescriptor` so the SubstitutionPolicy can
 * reason about it semantically. Routes chat-completion requests to
 * Ollama's OpenAI-compatibility endpoint.
 *
 * The adapter is dependency-free at runtime — it uses only `fetch`
 * (Node 18+ globalThis.fetch). The subprocess fallback (`ollama ls`)
 * is wired but unused in the default path because /api/tags is more
 * reliable; the subprocess path is exposed for future auditing tools.
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

const DEFAULT_BASE_URL = "http://127.0.0.1:11434";
const DETECT_TIMEOUT_MS = 1500;
const SUBPROCESS_TIMEOUT_MS = 8000;

export interface OllamaAdapterOptions {
  /** Override the Ollama base URL (default 127.0.0.1:11434). */
  baseUrl?: string;
  /** Use the `ollama ls` subprocess instead of /api/tags for enumeration. Default false. */
  useSubprocessEnumeration?: boolean;
  /**
   * Override the fetch impl for testing (defaults to globalThis.fetch).
   * Tests can pass an in-memory mock without hitting localhost.
   */
  fetchImpl?: typeof fetch;
}

interface OllamaTagsResponse {
  models?: Array<{
    name?: string;
    model?: string;
    modified_at?: string;
    size?: number;
    digest?: string;
    details?: {
      parameter_size?: string;
      quantization_level?: string;
      family?: string;
    };
  }>;
}

export class OllamaAdapter implements EngineAdapter {
  readonly name = "ollama";
  private readonly baseUrl: string;
  private readonly useSubprocess: boolean;
  private readonly fetchImpl: typeof fetch;

  constructor(opts: OllamaAdapterOptions = {}) {
    this.baseUrl = opts.baseUrl ?? DEFAULT_BASE_URL;
    this.useSubprocess = opts.useSubprocessEnumeration ?? false;
    this.fetchImpl = opts.fetchImpl ?? globalThis.fetch;
  }

  async detect(): Promise<boolean> {
    try {
      const res = await fetchWithTimeout(
        this.fetchImpl,
        `${this.baseUrl}/api/tags`,
        { method: "GET" },
        DETECT_TIMEOUT_MS,
      );
      return res.ok;
    } catch {
      return false;
    }
  }

  async enumerateCachedModels(): Promise<BackendDescriptor[]> {
    if (this.useSubprocess) {
      return this.enumerateViaSubprocess();
    }
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
      return {
        status: res.status,
        headers,
        body: streamFromBody(res.body),
      };
    }
    const body = (await res.json().catch(() => null)) as unknown;
    return {
      status: res.status,
      headers,
      body,
    };
  }

  async close(): Promise<void> {
    // No persistent state — fetch-based.
  }

  /* -------------------------------------------------------------- */
  /* Internals                                                      */
  /* -------------------------------------------------------------- */

  private async enumerateViaApi(): Promise<BackendDescriptor[]> {
    const res = await fetchWithTimeout(
      this.fetchImpl,
      `${this.baseUrl}/api/tags`,
      { method: "GET" },
      DETECT_TIMEOUT_MS * 2,
    );
    if (!res.ok) return [];
    const json = (await res.json().catch(() => null)) as OllamaTagsResponse | null;
    if (!json?.models) return [];
    return json.models
      .map((m): BackendDescriptor | null => {
        const id = m.name ?? m.model;
        if (!id) return null;
        return {
          descriptor: parseModelName(id),
          engine: this.name,
          engineModelId: id,
        };
      })
      .filter((b): b is BackendDescriptor => b !== null);
  }

  private async enumerateViaSubprocess(): Promise<BackendDescriptor[]> {
    try {
      const { stdout } = await execFileAsync("ollama", ["ls"], {
        timeout: SUBPROCESS_TIMEOUT_MS,
        windowsHide: true,
      });
      return parseOllamaListOutput(stdout, this.name);
    } catch {
      return [];
    }
  }
}

/* -------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Parse `ollama ls` table output (column-aligned). The format:
 *
 *   NAME                ID              SIZE      MODIFIED
 *   llama3.2:1b         abc123          1.3 GB    3 days ago
 *   gemma:2b            def456          1.7 GB    1 week ago
 *
 * Header row is detected by the literal "NAME" prefix.
 */
export function parseOllamaListOutput(
  stdout: string,
  engineName: string,
): BackendDescriptor[] {
  const lines = stdout.split(/\r?\n/);
  const out: BackendDescriptor[] = [];
  for (const line of lines) {
    if (!line.trim()) continue;
    if (/^\s*NAME\s+ID\b/i.test(line)) continue; // header
    // Take the first whitespace-separated token as the model name.
    const m = /^\s*(\S+)/.exec(line);
    if (!m) continue;
    const id = m[1]!;
    out.push({
      descriptor: parseModelName(id),
      engine: engineName,
      engineModelId: id,
    });
  }
  return out;
}

async function fetchWithTimeout(
  fetchImpl: typeof fetch,
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    return await fetchImpl(url, { ...init, signal: ctrl.signal });
  } finally {
    clearTimeout(timer);
  }
}

function headersToObject(h: Headers): Record<string, string> {
  const out: Record<string, string> = {};
  h.forEach((v, k) => {
    out[k] = v;
  });
  return out;
}

async function* streamFromBody(
  body: ReadableStream<Uint8Array>,
): AsyncIterable<Uint8Array> {
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
