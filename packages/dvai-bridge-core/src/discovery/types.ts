/**
 * Phase 3 — peer discovery types.
 *
 * A "peer" is another device running dvai-bridge that this device can
 * (potentially) offload inference requests to. Peers are surfaced by
 * one or more `IDiscovery` impls — LAN mDNS, app-supplied static list,
 * rendezvous-paired (internet), or a host-app-provided custom source.
 */

export interface Peer {
  /** Stable per-install device ID of the peer. */
  deviceId: string;
  /** Human-readable hint (iOS device name, hostname, etc.). */
  deviceName: string;
  /** Library SemVer the peer is running. */
  dvaiVersion: string;
  /** OpenAI-compatible base URL the peer's local server exposes. */
  baseUrl: string;
  /**
   * v3.1 wire-protocol extension. Identifies which application on the
   * peer device is making the request — used by multi-tenant targets
   * (the Hub) to isolate per-app state. Optional for backwards compat
   * with v3.0 SDKs that don't send this field.
   */
  appId?: string;
  /**
   * Models the peer claims to have loaded right now. Used to filter
   * peer eligibility — we only offload model X to a peer that already
   * has model X loaded (loading from scratch on the peer is fine but
   * defeats the latency win).
   */
  loadedModels: string[];
  /**
   * Peer-reported capability map: { modelId → tok/s }. Treat as
   * advisory only; the offload decider re-probes a peer with a small
   * reachability+decode test before its first real offload request.
   */
  capability: Record<string, number>;
  /** Discovery source — useful for diagnostics and the structured-error response. */
  via: "mdns" | "static" | "rendezvous" | "custom";
  /** Whether the peer's URL uses TLS. */
  secure: boolean;
  /** Last-seen unix ms — discovery sources update this. */
  lastSeenAt: number;
}

export type DiscoveryEvent =
  | { type: "peer-up"; peer: Peer }
  | { type: "peer-down"; deviceId: string }
  | { type: "error"; message: string };

/**
 * The contract every discovery source implements. Used by the
 * composite discovery layer.
 */
export interface IDiscovery {
  /** Begin discovering. Idempotent. */
  start(): Promise<void>;
  /** Stop and release resources. Idempotent. */
  stop(): Promise<void>;
  /** Snapshot of currently-known peers. */
  peers(): Peer[];
  /** Subscribe to discovery events. Returns unsubscribe fn. */
  subscribe(listener: (e: DiscoveryEvent) => void): () => void;
}

/** Service-type advertised on mDNS for dvai-bridge instances. */
export const MDNS_SERVICE_TYPE = "_dvai-bridge._tcp.local";
