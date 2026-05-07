import type { HandlerContext } from "../handlers/context.js";

export type TransportKind = "msw" | "http" | "none" | "capacitor";

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
  /**
   * Network interface to bind the HTTP server to. Default `127.0.0.1`
   * (loopback only). Set to `0.0.0.0` for LAN-target deployments
   * (the v3.1 Hub, native SDKs running in target mode) so peers on
   * the same Wi-Fi can reach the server.
   *
   * Phone-as-source / single-device deployments should leave this at
   * the default — a 0.0.0.0 bind on a developer laptop with no
   * pairing protection would expose the OpenAI surface to the LAN.
   */
  bindHost?: string;
}

export interface MswTransportOptions {
  /** URL MSW intercepts, including /v1/chat/completions suffix. */
  mockUrl: string;
  /** Path to the msw service worker script. */
  serviceWorkerUrl: string;
}
