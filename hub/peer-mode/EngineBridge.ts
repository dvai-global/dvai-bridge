/**
 * Phase 4 — DVAI Hub External-Engine Bridge.
 *
 * The Hub's first-party local backends (the same set @dvai-bridge/core
 * exposes) cover the common cases. But many users already have an
 * external engine running — Ollama, LM Studio, vLLM, llama-server. The
 * EngineBridge is an opt-in framework that lets the Hub *also* surface
 * those engines' cached models, so a paired mobile app's request can
 * be served by whichever engine has the right model loaded.
 *
 * Each adapter implements a tiny contract:
 *   - `detect()` — is the engine running locally?
 *   - `enumerateCachedModels()` — what does it have cached?
 *   - `serveRequest()` — proxy a chat-completion through to it.
 *
 * The bridge framework caches the enumeration with a TTL so we don't
 * spawn a subprocess on every request, and re-enumerates on demand
 * when the user clicks "Rescan" in the dashboard.
 */

import type { ModelDescriptor } from "./ModelParser.js";
import type { BackendDescriptor } from "./SubstitutionPolicy.js";

/** Public-shape OpenAI-style chat completion request. The bridge is wire-format-agnostic. */
export interface ChatRequest {
  model: string;
  messages: Array<{ role: string; content: unknown }>;
  stream?: boolean;
  temperature?: number;
  max_tokens?: number;
  [key: string]: unknown;
}

/** Non-streaming response (passes through whatever the engine emits). */
export interface ChatResponse {
  status: number;
  headers: Record<string, string>;
  body: unknown;
}

/**
 * Streaming response (SSE). The bridge proxies bytes through verbatim;
 * we expose the raw stream + headers so the caller can pipe the SSE
 * back to the requesting peer without re-parsing.
 */
export interface StreamResponse {
  status: number;
  headers: Record<string, string>;
  /** Async iterator yielding raw SSE chunks. */
  body: AsyncIterable<Uint8Array>;
}

export interface EngineAdapter {
  /** Stable adapter id, e.g. "ollama" / "lmstudio". Used in audit logs. */
  readonly name: string;
  /** True if the engine is reachable locally right now. */
  detect(): Promise<boolean>;
  /** Returns the engine's full cached-model catalog. May be expensive (subprocess). */
  enumerateCachedModels(): Promise<BackendDescriptor[]>;
  /** Serve a chat-completion request through the engine. */
  serveRequest(
    descriptor: ModelDescriptor,
    request: ChatRequest,
  ): Promise<ChatResponse | StreamResponse>;
  /** Release adapter resources (close pools, kill subprocess pipes). */
  close(): Promise<void>;
}

export interface EngineSummary {
  /** Adapter name. */
  name: string;
  /** True if `detect()` returned true at the last check. */
  detected: boolean;
  /** Number of models the adapter currently exposes (cached count). */
  modelCount: number;
  /** Last-enumerated unix-ms timestamp (0 if never). */
  lastEnumeratedAt: number;
}

export interface EngineBridgeOptions {
  /** Master switch — false means the bridge surfaces no external engines. */
  enabled: boolean;
  /** Adapter instances to drive. The bridge does not own their construction. */
  adapters: EngineAdapter[];
  /** How long enumeration results are cached before re-running (default 5 min). */
  cacheTtlMs?: number;
}

interface CacheEntry {
  models: BackendDescriptor[];
  enumeratedAt: number;
  detected: boolean;
}

const DEFAULT_TTL_MS = 5 * 60 * 1000;

export class EngineBridge {
  private readonly enabled: boolean;
  private readonly adapters: EngineAdapter[];
  private readonly ttlMs: number;
  private readonly cache = new Map<string, CacheEntry>();
  private started = false;

  constructor(opts: EngineBridgeOptions) {
    this.enabled = opts.enabled;
    this.adapters = opts.adapters;
    this.ttlMs = opts.cacheTtlMs ?? DEFAULT_TTL_MS;
  }

  /**
   * Detect each adapter and warm the enumeration cache. Idempotent — a
   * second call refreshes detection state but doesn't re-enumerate
   * unless the cache is stale.
   */
  async start(): Promise<void> {
    if (!this.enabled) {
      this.started = true;
      return;
    }
    await Promise.all(
      this.adapters.map(async (adapter) => {
        const detected = await safeDetect(adapter);
        if (!detected) {
          this.cache.set(adapter.name, { models: [], enumeratedAt: 0, detected: false });
          return;
        }
        const models = await safeEnumerate(adapter);
        this.cache.set(adapter.name, {
          models,
          enumeratedAt: Date.now(),
          detected: true,
        });
      }),
    );
    this.started = true;
  }

  async stop(): Promise<void> {
    await Promise.all(this.adapters.map((adapter) => safeClose(adapter)));
    this.cache.clear();
    this.started = false;
  }

  /** Snapshot of every adapter's status. */
  detected(): EngineSummary[] {
    return this.adapters.map((adapter) => {
      const entry = this.cache.get(adapter.name);
      return {
        name: adapter.name,
        detected: entry?.detected ?? false,
        modelCount: entry?.models.length ?? 0,
        lastEnumeratedAt: entry?.enumeratedAt ?? 0,
      };
    });
  }

  /**
   * Returns the union of every adapter's cached model catalog. Re-enumerates
   * any adapter whose cache is older than `ttlMs`. Adapters that fail to
   * detect or enumerate are silently skipped — the bridge never throws on
   * partial failure (one engine being down shouldn't break Hub).
   */
  async enumerateAvailable(): Promise<BackendDescriptor[]> {
    if (!this.enabled || !this.started) return [];

    const out: BackendDescriptor[] = [];
    for (const adapter of this.adapters) {
      const entry = this.cache.get(adapter.name);
      const stale = !entry || Date.now() - entry.enumeratedAt >= this.ttlMs;
      if (stale) {
        const detected = await safeDetect(adapter);
        if (!detected) {
          this.cache.set(adapter.name, { models: [], enumeratedAt: Date.now(), detected: false });
          continue;
        }
        const models = await safeEnumerate(adapter);
        this.cache.set(adapter.name, {
          models,
          enumeratedAt: Date.now(),
          detected: true,
        });
        out.push(...models);
      } else if (entry.detected) {
        out.push(...entry.models);
      }
    }
    return out;
  }

  /** Force re-enumeration of one adapter on next access (or all, if no name). */
  async invalidateCache(adapterName?: string): Promise<void> {
    if (adapterName === undefined) {
      this.cache.clear();
      return;
    }
    this.cache.delete(adapterName);
  }

  /** Look up the adapter that owns a backend descriptor (by engine name). */
  findAdapter(engineName: string): EngineAdapter | undefined {
    return this.adapters.find((a) => a.name === engineName);
  }
}

/* -------------------------------------------------------------------------- */
/* Defensive wrappers — adapter failures must never crash the bridge.         */
/* -------------------------------------------------------------------------- */

async function safeDetect(adapter: EngineAdapter): Promise<boolean> {
  try {
    return await adapter.detect();
  } catch {
    return false;
  }
}

async function safeEnumerate(adapter: EngineAdapter): Promise<BackendDescriptor[]> {
  try {
    return await adapter.enumerateCachedModels();
  } catch {
    return [];
  }
}

async function safeClose(adapter: EngineAdapter): Promise<void> {
  try {
    await adapter.close();
  } catch {
    /* best-effort */
  }
}
