import type { HandlerContext } from "../handlers/context.js";

export type TransportKind = "msw" | "http" | "none";

export interface TransportStartResult {
  /** URL a host app hands to an OpenAI SDK (no trailing slash). */
  baseUrl: string;
  /** Populated only for http transport; undefined for msw/none. */
  port?: number;
}

export interface Transport {
  readonly kind: TransportKind;
  start(ctx: HandlerContext): Promise<TransportStartResult>;
  /** Idempotent; safe to call multiple times. */
  stop(): Promise<void>;
}

export interface HttpTransportOptions {
  httpBasePort: number;
  httpMaxPortAttempts: number;
  corsOrigin: string | string[];
}

export interface MswTransportOptions {
  /** URL MSW intercepts, including /v1/chat/completions suffix. */
  mockUrl: string;
  /** Path to the msw service worker script. */
  serviceWorkerUrl: string;
}
