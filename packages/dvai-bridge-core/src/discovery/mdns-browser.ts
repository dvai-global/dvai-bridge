/**
 * Browser-side mDNS adapter — a no-op.
 *
 * Browsers don't speak mDNS. They CAN'T accept inbound HTTP requests
 * across origins reliably either, so even if we could discover peers
 * on the LAN, the browser couldn't act as an offload TARGET. Browser
 * is offload-source-only; native devices are the offload targets it
 * pairs with via the rendezvous server.
 *
 * This file exists so the composite discovery layer can pick a
 * runtime-appropriate impl without an `if (browser)` check.
 */

import type { DiscoveryEvent, IDiscovery, Peer } from "./types.js";

export class BrowserMdnsDiscovery implements IDiscovery {
  // Empty — browsers can't speak mDNS, but this slot keeps the
  // composite discovery layer's typing clean.
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  constructor(_opts: unknown = {}) {}

  async start(): Promise<void> {
    // No-op. Diagnostic log is at TRACE level only — this isn't an
    // error condition; it's an architectural fact.
  }
  async stop(): Promise<void> {
    // No-op.
  }
  peers(): Peer[] {
    return [];
  }
  subscribe(_listener: (e: DiscoveryEvent) => void): () => void {
    return () => {};
  }
}
