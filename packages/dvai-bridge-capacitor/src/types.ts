/**
 * @dvai-bridge/capacitor — public type definitions.
 * These types are also imported by backend plugin packages
 * (capacitor-llama, capacitor-foundation, capacitor-mediapipe)
 * to keep the JS↔native contract consistent.
 */

export type CapacitorBackend = "llama" | "foundation" | "mediapipe" | "mlx";

export interface StartOptions {
  /** Which native backend plugin to dispatch to. */
  backend: CapacitorBackend;
  /** Path to the GGUF model file (llama backend) or .task file (mediapipe). Not used by foundation. */
  modelPath?: string;
  /** Optional path to mmproj (vision projector) for llama vision models. */
  mmprojPath?: string;
  /** Llama: GPU layers offloaded (default 99 = max). */
  gpuLayers?: number;
  /** Llama / mediapipe: context window. */
  contextSize?: number;
  /** Llama: CPU threads. */
  threads?: number;
  /** Llama: initialize in embedding mode (chat will not work; embeddings will). */
  embeddingMode?: boolean;
  /** HTTP server base port; retries +1 up to httpMaxPortAttempts on EADDRINUSE. Default 38883. */
  httpBasePort?: number;
  /** Default 16. */
  httpMaxPortAttempts?: number;
  /** CORS Access-Control-Allow-Origin. "*", a single origin, or a list. Default "*". */
  corsOrigin?: string | string[];
  /** Auto-unload the model when OS emits low-memory warning. Default false. */
  autoUnloadOnLowMemory?: boolean;
  /** Native log verbosity. Default "info". */
  logLevel?: "silent" | "info" | "debug";
  /**
   * v3.0+ — distributed inference / device offload.
   *
   * When `offload.enabled` is true, the native side runs mDNS discovery
   * (and optionally a rendezvous WebSocket) to find peer dvai-bridge
   * instances and offloads inference requests when the local device
   * can't serve the model fast enough. See
   * [the distributed-inference guide](https://dvai-bridge.deepvoiceai.co/guide/distributed-inference)
   * for the full contract.
   *
   * Pairing-request UI is surfaced via the `"pairingRequest"` event
   * (see {@link DVAIBridge.addListener}); the function callback in the
   * JS-side `OffloadConfig.onPairingRequest` cannot cross the Capacitor
   * plugin boundary, so consumers use the event surface instead.
   */
  offload?: OffloadConfig;

  /**
   * v3.2.2+ — path (or fetchable URL) to your DVAI-Bridge license JWT.
   *
   * The Capacitor bridge forwards this string to the native backend
   * plugin (`DVAIBridgeLlama`, `DVAIBridgeFoundation`,
   * `DVAIBridgeMediaPipe`, `DVAIBridgeMLX`). Each native validator runs
   * its own offline JWT verification (signature + expiry + audience +
   * platform binding) against the iOS bundle identifier or Android
   * package name — see `@dvai-bridge/core/license` for the canonical
   * JWT format. The validators are authoritative; this JS-side
   * forwarding is the only plumbing needed.
   *
   * Override priority on the native side (matches `DVAIConfig`):
   *   1. `licenseToken` (below) — inline JWT string, highest priority
   *   2. `licenseKeyPath` (this field) — explicit path or URL
   *   3. Platform default locations + env-var fallbacks
   *
   * Free-tier behaviour (no license, expired, invalid) is enforced by
   * the native validator and surfaced via the platform's standard
   * error channel. The JS layer never inspects this value beyond
   * forwarding it.
   */
  licenseKeyPath?: string;

  /**
   * v3.2.2+ — inline DVAI-Bridge license JWT (the full token string).
   *
   * Use when injecting the license via runtime config rather than a
   * bundled file — typical for over-the-air license refresh or when
   * the same Capacitor binary serves multiple licensees that each
   * receive their own token from your backend.
   *
   * If both `licenseToken` and `licenseKeyPath` are set, `licenseToken`
   * wins on the native side.
   */
  licenseToken?: string;
}

/**
 * v3.0+ — distributed inference / device offload config. Wire-friendly
 * subset of the JS-side `@dvai-bridge/core` `OffloadConfig` — function
 * callbacks (`onPairingRequest`, `onOffload`, `customDiscovery`) are not
 * representable across the Capacitor plugin boundary, so they're surfaced
 * via {@link DVAIBridge.addListener}'s `"pairingRequest"` channel instead.
 *
 * See [the distributed-inference guide](https://dvai-bridge.deepvoiceai.co/guide/distributed-inference)
 * for the full feature description.
 */
export interface OffloadConfig {
  /** Master switch. Default false; offload is opt-in at v3.0. */
  enabled: boolean;
  /** Run mDNS to discover LAN peers. Default: true when `enabled`. */
  discoverLAN?: boolean;
  /** Below this tok/s, look for a peer. Default: 10. */
  minLocalCapability?: number;
  /** Optional rendezvous-server URL — enables internet path if set. */
  rendezvousUrl?: string;
  /** Optional pre-known peers (skip discovery). */
  knownPeers?: Peer[];
}

/**
 * Peer dvai-bridge instance discovered on the LAN or via rendezvous.
 * Mirrors `@dvai-bridge/core` `Peer` 1:1 across SDKs. Surfaced via
 * {@link PairingRequest.peer} and consumed via {@link OffloadConfig.knownPeers}.
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
  /** Models the peer claims to have loaded right now. */
  loadedModels: string[];
  /** Peer-reported capability map: `{ modelId → tok/s }`. Advisory. */
  capability: Record<string, number>;
  /** Discovery source. */
  via: "mdns" | "static" | "rendezvous" | "custom";
  /** Whether the peer's URL uses TLS. */
  secure: boolean;
  /** Last-seen unix ms. */
  lastSeenAt: number;
}

/**
 * A request for the consumer app to approve (or deny) pairing with a
 * remote peer. Emitted on the `"pairingRequest"` channel
 * (see {@link DVAIBridge.addListener}). The consumer calls
 * {@link DVAIBridge.respondToPairing} with the {@link PairingRequest.id}
 * and the user's decision.
 */
export interface PairingRequest {
  /** Stable id used to correlate the response via {@link DVAIBridge.respondToPairing}. */
  id: string;
  /** The peer requesting to pair. */
  peer: Peer;
  /**
   * Convenience accessor for `peer.deviceName`. The migration guide and
   * iOS `PairingRequest.peerDeviceName` use this name; surfacing it
   * directly keeps consumer-facing code shorter.
   */
  peerDeviceName: string;
  /** Unix-ms deadline after which the pending request is auto-denied. */
  expiresAt: number;
}

export interface StartResult {
  /** URL the host app passes to its OpenAI SDK. e.g. "http://127.0.0.1:38883/v1". */
  baseUrl: string;
  /** Bound HTTP port. */
  port: number;
  /** Resolved backend. */
  backend: CapacitorBackend;
  /** Model identifier echoed in /v1/models responses. */
  modelId: string;
}

/**
 * Lifecycle progress event emitted by `addProgressListener`.
 *
 * Phase semantics:
 * - `"download"`: bytes streaming from a remote URL into the on-disk
 *   `.partial` file. `bytesReceived` / `bytesTotal` / `percent` populated.
 * - `"verify"`: final sha256 check after download completes (or after a
 *   resumed `.partial` is rehashed). Usually no byte fields.
 * - `"load"`: native plugin loading the model into engine memory
 *   (mmap / GPU upload / etc.). Usually no byte fields; some backends
 *   may report `percent`.
 * - `"ready"`: terminal state, model is live and serving.
 * - `"error"`: terminal state, populated `message` describes the failure.
 */
export interface ProgressEvent {
  phase: "download" | "verify" | "load" | "ready" | "error";
  bytesReceived?: number;
  bytesTotal?: number;
  percent?: number;
  message?: string;
}

export interface StatusInfo {
  running: boolean;
  backend?: CapacitorBackend;
  baseUrl?: string;
}

export interface DownloadOptions {
  /** Source URL (HTTP or HTTPS). */
  url: string;
  /** Required SHA-256 of the final file (lowercase hex). */
  sha256: string;
  /** Override destination filename. Default: URL basename. */
  destFilename?: string;
  /** Extra request headers (e.g. for HuggingFace gated repos). */
  headers?: Record<string, string>;
  /** Progress callback. Throttled to ~10 calls/sec. */
  onProgress?: (e: ProgressEvent) => void;
}

export interface CachedModelInfo {
  filename: string;
  path: string;
  bytes: number;
  sha256: string;
}

/**
 * Native plugin interface — what each backend plugin (llama, foundation,
 * mediapipe) implements on the native side. The JS shim calls these.
 */
export interface NativePluginInterface {
  start(options: StartOptions): Promise<StartResult>;
  stop(): Promise<void>;
  status(): Promise<StatusInfo>;
  downloadModel(options: DownloadOptions): Promise<{ path: string; cached: boolean }>;
  listCachedModels(): Promise<{ models: CachedModelInfo[] }>;
  deleteCachedModel(options: { filename: string }): Promise<void>;
  cacheDir(): Promise<{ path: string }>;
  addListener(eventName: "progress", listenerFunc: (e: ProgressEvent) => void): Promise<{ remove: () => Promise<void> }>;
  /**
   * v3.0+ — distributed inference. Subscribe to inbound pairing
   * requests emitted when a remote peer wants to pair with this device.
   * Consumers respond by calling {@link respondToPairing} with the
   * request's `id` and a boolean decision.
   */
  addListener(eventName: "pairingRequest", listenerFunc: (req: PairingRequest) => void): Promise<{ remove: () => Promise<void> }>;
  /**
   * v3.0+ — distributed inference. Resolve a pending {@link PairingRequest}
   * by `id`. Idempotent — responding twice resolves cleanly.
   */
  respondToPairing(options: { requestId: string; approved: boolean }): Promise<void>;
}
