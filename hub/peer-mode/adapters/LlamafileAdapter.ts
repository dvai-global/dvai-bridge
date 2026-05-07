/**
 * Phase 4 — Llamafile EngineAdapter.
 *
 * Llamafile binaries are *standalone executables* — there is no
 * always-on HTTP server. The adapter does NOT serve requests directly;
 * instead it enumerates `*.llamafile` (and `*.llamafile.exe`) under
 * a configurable directory so the user can see them in the dashboard.
 *
 * `serveRequest` is wired but only succeeds when a llamafile is
 * already running with `--server` and exposing OpenAI-compat at the
 * `runningBaseUrl` the user configures (matches the llamafile launch
 * command). This keeps the adapter forward-compatible with the
 * eventual "Hub launches the llamafile on demand" feature without
 * blocking v3.1 on it.
 */

import { promises as fs } from "node:fs";
import * as path from "node:path";
import { homedir } from "node:os";
import { parseModelName } from "../ModelParser.js";
import type {
  ChatRequest,
  ChatResponse,
  EngineAdapter,
  StreamResponse,
} from "../EngineBridge.js";
import type { BackendDescriptor } from "../SubstitutionPolicy.js";

export interface LlamafileAdapterOptions {
  /** Directory to scan for *.llamafile binaries. Default `~/.llamafile`. */
  scanDir?: string;
  /**
   * If a llamafile is running with `--server` enabled, point to its
   * baseUrl so `serveRequest` can route. Default: undefined (request
   * routing returns a 503-shaped response).
   */
  runningBaseUrl?: string;
  /** Override the FS impl for testing. */
  fsImpl?: { readdir: (dir: string) => Promise<string[]> };
  /** Override the fetch impl (only used when runningBaseUrl is set). */
  fetchImpl?: typeof fetch;
}

const DEFAULT_DIR = path.join(homedir(), ".llamafile");

export class LlamafileAdapter implements EngineAdapter {
  readonly name = "llamafile";
  private readonly scanDir: string;
  private readonly runningBaseUrl: string | undefined;
  private readonly fsImpl: { readdir: (dir: string) => Promise<string[]> };
  private readonly fetchImpl: typeof fetch;

  constructor(opts: LlamafileAdapterOptions = {}) {
    this.scanDir = opts.scanDir ?? DEFAULT_DIR;
    this.runningBaseUrl = opts.runningBaseUrl;
    this.fsImpl = opts.fsImpl ?? {
      readdir: async (dir: string): Promise<string[]> => {
        const entries = await fs.readdir(dir);
        return entries;
      },
    };
    this.fetchImpl = opts.fetchImpl ?? globalThis.fetch;
  }

  async detect(): Promise<boolean> {
    try {
      const entries = await this.fsImpl.readdir(this.scanDir);
      return entries.some((name) => isLlamafileEntry(name));
    } catch {
      return false;
    }
  }

  async enumerateCachedModels(): Promise<BackendDescriptor[]> {
    let entries: string[];
    try {
      entries = await this.fsImpl.readdir(this.scanDir);
    } catch {
      return [];
    }
    const out: BackendDescriptor[] = [];
    for (const name of entries) {
      if (!isLlamafileEntry(name)) continue;
      // Strip the .llamafile / .llamafile.exe suffix so the parser
      // can read the model bits. e.g. "llava-v1.5-7b-q4.llamafile"
      // → parsed family=llama (via llava→llama), size=7b, quant=q4.
      const stripped = name.replace(/\.llamafile(\.exe)?$/i, "");
      out.push({
        descriptor: parseModelName(stripped),
        engine: this.name,
        engineModelId: name,
      });
    }
    return out;
  }

  async serveRequest(
    _descriptor: import("../ModelParser.js").ModelDescriptor,
    request: ChatRequest,
  ): Promise<ChatResponse | StreamResponse> {
    if (!this.runningBaseUrl) {
      return {
        status: 503,
        headers: { "content-type": "application/json" },
        body: {
          error: {
            type: "llamafile_not_running",
            message:
              "No running llamafile server is configured. Launch the llamafile binary with `--server` and set runningBaseUrl in the LlamafileAdapter options.",
          },
        },
      };
    }
    const url = `${this.runningBaseUrl}/v1/chat/completions`;
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
}

function isLlamafileEntry(name: string): boolean {
  return /\.llamafile(\.exe)?$/i.test(name);
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
