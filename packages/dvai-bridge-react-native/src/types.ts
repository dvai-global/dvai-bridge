/**
 * Public type surface of `@dvai-bridge/react-native`. Mirrors the iOS
 * `DVAIBridgeConfig` / `BoundServer` / `ProgressEvent` and Android
 * `StartOptions` / `BoundServer` / `ProgressEvent` shapes 1:1, with the
 * following adaptations for JS:
 *
 *  - `BackendKind` is the **union** of the iOS-side and Android-side cases.
 *    Lower-cased string-enum values for JSON-friendliness.
 *  - All numeric fields are `number` (RN's TurboModule codegen has a single
 *    `Double`-backed numeric type — the Swift / Kotlin sides cast back to
 *    `Int` where appropriate).
 *  - Optional fields use TS `?` rather than separate union-with-undefined.
 */

/**
 * Inference backend selected via {@link StartOptions.backend}. The TS API
 * exposes the **union** of every backend supported by either platform.
 *
 * Cross-platform availability:
 *
 *  | Value           | iOS  | Android |
 *  |-----------------|:----:|:-------:|
 *  | `"auto"`        |  ✓   |    ✓    |
 *  | `"llama"`       |  ✓   |    ✓    |
 *  | `"foundation"`  |  ✓   |    —    |
 *  | `"coreml"`      |  ✓   |    —    |
 *  | `"mlx"`         |  ✓*  |    —    |
 *  | `"mediapipe"`   |  —   |    ✓    |
 *  | `"litert"`      |  —   |    ✓    |
 *
 * `*` MLX is SwiftPM-only — see the README's "MLX under CocoaPods" note.
 *
 * Selecting a backend that the running platform doesn't support throws
 * {@link DVAIBridgeError} with `kind: "backendUnavailable"`. The TS facade
 * raises that error eagerly (before invoking the native module) so JS-side
 * callers don't have to wait on a native round-trip for the obvious case.
 */
export const BackendKind = {
  Auto: "auto",
  Llama: "llama",
  Foundation: "foundation",
  CoreML: "coreml",
  MLX: "mlx",
  MediaPipe: "mediapipe",
  LiteRT: "litert",
} as const;

export type BackendKind = (typeof BackendKind)[keyof typeof BackendKind];

/**
 * CORS allow-origin policy for the embedded HTTP server.
 *
 *  - `"*"` (or omitted): wildcard.
 *  - A single string: exact origin (e.g. `"https://app.example.com"`).
 *  - An array of strings: explicit allowlist.
 */
export type CorsOrigin = "*" | string | string[];

/**
 * Options for {@link DVAIBridge.start}. Shape matches iOS `DVAIBridgeConfig`
 * and Android `StartOptions`.
 *
 * Every field is optional except `backend`. Per-backend defaults match the
 * native SDKs (see the per-platform docs for the full list).
 */
export interface StartOptions {
  /** Which backend to start. Pass {@link BackendKind.Auto} to resolve at runtime. */
  backend: BackendKind;
  /**
   * Filesystem path to the model checkpoint. Required for `llama` (`.gguf`),
   * `mediapipe` (`.task`), `litert` (`.tflite` / `.litertlm`), and `coreml`
   * (`.mlmodelc` / `.mlpackage`) backends. For `mlx`, pass a HuggingFace
   * model id (e.g. `"mlx-community/Llama-3.2-1B-Instruct-4bit"`). Optional
   * for `foundation` (Apple's bundled model).
   */
  modelPath?: string;
  /** Optional path to a directory containing `tokenizer.json`. Required for the LiteRT backend. */
  tokenizerPath?: string;
  /** Optional multimodal projector path (Llama backend, vision/audio LLMs). */
  mmprojPath?: string;
  /** Optional Jinja chat-template override (Llama backend). Falls back to the model's bundled template. */
  chatTemplate?: string;
  /** Optional override for the model id surfaced via `/v1/models`. Defaults to filename minus extension. */
  modelId?: string;
  /** Llama backend: layers offloaded to GPU. 99 = all, 0 = CPU only. Default: 99. */
  gpuLayers?: number;
  /** Context window in tokens. Default: 2048. */
  contextSize?: number;
  /** CPU thread count for inference. Default: 4. */
  threads?: number;
  /** Llama backend: open in embedding-extraction mode rather than completion mode. Default: false. */
  embeddingMode?: boolean;
  /** MediaPipe backend: enable the LiteRT-LM vision backend (Gemma 3n). Default: false. */
  visionEnabled?: boolean;
  /** LiteRT backend: sampling temperature (0 = greedy). Default: 0. */
  temperature?: number;
  /** LiteRT backend: nucleus-sampling cutoff (1 = disabled). Default: 1. */
  topP?: number;
  /** LiteRT backend: top-K truncation (0 = disabled). Default: 0. */
  topK?: number;
  /** LiteRT backend: hard cap on tokens generated per request. Default: 512. */
  maxNewTokens?: number;
  /** First port the embedded HTTP server tries to bind. Default: 38883. */
  httpBasePort?: number;
  /** Number of consecutive ports to try before giving up. Default: 16. */
  httpMaxPortAttempts?: number;
  /** CORS allow-origin policy. Default: wildcard. */
  corsOrigin?: CorsOrigin;
  /** iOS only: log level (`"silent"` | `"info"` | `"debug"`). Default: `"info"`. */
  logLevel?: "silent" | "info" | "debug";
  /** iOS only: auto-unload the active model on iOS memory-pressure events. Default: false. */
  autoUnloadOnLowMemory?: boolean;
  /**
   * v3.0+ — distributed inference / device offload.
   *
   * When `offload.enabled` is true, the native side runs mDNS discovery
   * (and optionally a rendezvous WebSocket) to find peer dvai-bridge
   * instances and offloads inference requests when the local device
   * can't serve the model fast enough. See
   * [the distributed-inference guide](https://bridge.deepvoiceai.co/guide/distributed-inference)
   * for the full contract.
   *
   * Pairing-request UI is surfaced via the `"pairingRequest"` event
   * (see {@link DVAIBridge.addListener}); the native callback in
   * {@link OffloadConfig.onPairingRequest} cannot cross the TurboModule
   * boundary, so RN consumers use the event surface instead.
   */
  offload?: OffloadConfig;

  /**
   * v3.2.2+ — path (or fetchable URL) to your DVAI-Bridge license JWT.
   *
   * Forwarded as-is to the iOS / Android TurboModule, which runs the
   * authoritative offline JWT verification (signature + expiry +
   * audience + platform binding) against the platform's native bundle
   * identifier (`Bundle.main.bundleIdentifier` on iOS,
   * `context.packageName` on Android). React Native's JS layer cannot
   * read those identifiers, so license enforcement lives entirely on
   * the native side; the JS layer's only job is to pass the field
   * through.
   *
   * Override priority on the native side (matches the JS-side
   * `DVAIConfig`):
   *   1. `licenseToken` (below) — inline JWT string, highest priority
   *   2. `licenseKeyPath` (this field) — explicit path or URL
   *   3. Platform default locations + env-var fallbacks
   *
   * Free-tier behaviour (no license, expired, invalid) is enforced by
   * the native validator and surfaced via `DVAIBridgeError` with the
   * native side's chosen `kind`. The JS layer never inspects this
   * value beyond forwarding it.
   */
  licenseKeyPath?: string;

  /**
   * v3.2.2+ — inline DVAI-Bridge license JWT (the full token string).
   *
   * Use when fetching the token at runtime (e.g. from your backend
   * after the user signs in) rather than shipping a file alongside
   * the app bundle. Useful for OTA license refresh or multi-tenant
   * deployments where the same RN binary serves multiple licensees.
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
 * representable across the TurboModule boundary, so they're surfaced via
 * the {@link DVAIBridge.addListener} event channel instead.
 *
 * See [the distributed-inference guide](https://bridge.deepvoiceai.co/guide/distributed-inference)
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
 * Mirrors `@dvai-bridge/core` `Peer` 1:1, except all numeric fields are
 * `number` (TurboModule wire-format constraint). Surfaced via
 * {@link PairingRequest.peer} and consumed via {@link StartOptions.offload}'s
 * `knownPeers`.
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

/**
 * Result of a successful {@link DVAIBridge.start} call. Mirrors iOS
 * `BoundServer` and Android `BoundServer`.
 */
export interface BoundServer {
  /** Full base URL of the embedded OpenAI-compatible server, e.g. `http://127.0.0.1:38883/v1`. */
  baseUrl: string;
  /** Port the HTTP server actually bound to (port-fallback may have moved it past `httpBasePort`). */
  port: number;
  /** The backend that actually loaded — useful when {@link StartOptions.backend} was `"auto"`. */
  backend: BackendKind;
  /** Stable identifier for the loaded model. Surfaced in the `model` field of every OpenAI response. */
  modelId: string;
}

/** Read-only snapshot returned by {@link DVAIBridge.status}. */
export interface StatusInfo {
  /** Whether a backend is currently active. */
  running: boolean;
  /** Base URL of the active server, when {@link running} is true. */
  baseUrl?: string;
  /** Bound port, when {@link running} is true. */
  port?: number;
  /** Active backend, when {@link running} is true. */
  backend?: BackendKind;
  /** Active model id, when {@link running} is true. */
  modelId?: string;
}

/** Options for {@link DVAIBridge.downloadModel}. */
export interface DownloadOptions {
  /** Source URL. HTTPS only. */
  url: string;
  /** Expected SHA-256 (lowercase hex). The downloader rejects mismatches and deletes the partial file. */
  sha256: string;
  /** Optional override for the on-disk filename. Defaults to the URL's last path component. */
  destFilename?: string;
  /** Optional extra HTTP request headers (e.g. `Authorization`). */
  headers?: Record<string, string>;
}

/** Result of a successful {@link DVAIBridge.downloadModel} call. */
export interface DownloadResult {
  /** Absolute filesystem path of the cached file. */
  path: string;
  /** SHA-256 of the cached file (echoes the requested checksum on success). */
  sha256: string;
  /** File size in bytes. */
  sizeBytes: number;
  /** Whether the cached copy was already present (no network traffic). */
  cached?: boolean;
}

/**
 * Lifecycle phase a {@link ProgressEvent} relates to.
 *
 *  - `"start"`: backend boot — invoked from {@link DVAIBridge.start}.
 *  - `"stop"`: shutdown — invoked from {@link DVAIBridge.stop}.
 *  - `"download"`: model download — invoked from {@link DVAIBridge.downloadModel}.
 */
export type ProgressPhase = "start" | "stop" | "download";

/**
 * Discriminated union of progress events emitted on the
 * `"DVAIBridgeProgress"` event-emitter channel. Both native sides emit
 * exactly this shape (see Phase 3E spec §3.5).
 */
export type ProgressEvent =
  | {
      kind: "started";
      phase: ProgressPhase;
      message?: string;
    }
  | {
      kind: "progress";
      phase: ProgressPhase;
      /** Percent in `[0, 100]` when known; omitted when indeterminate. */
      percent?: number;
      message?: string;
    }
  | {
      kind: "completed";
      phase: ProgressPhase;
      message?: string;
    }
  | {
      kind: "failed";
      phase: ProgressPhase;
      error: {
        kind: DVAIBridgeErrorKind;
        message: string;
      };
    };

/**
 * Stable error-code surface mirrored by iOS `DVAIBridgeError` cases and
 * Android `DVAIBridgeError` subclasses. The TS facade re-throws as
 * `DVAIBridgeError` (see `errors.ts`) preserving the `kind`.
 */
export type DVAIBridgeErrorKind =
  | "alreadyStarted"
  | "notStarted"
  | "configurationInvalid"
  | "modelLoadFailed"
  | "backendUnavailable"
  | "backendError"
  | "checksumMismatch"
  | "downloadFailed";

/**
 * Reactive view of the running bridge state, surfaced by
 * {@link useDVAIBridgeState}.
 */
export interface DVAIBridgeState {
  /** Whether the bridge is currently running. */
  isReady: boolean;
  /** Active server URL, when running. */
  baseUrl?: string;
  /** Active port, when running. */
  port?: number;
  /** Active backend, when running. */
  backend?: BackendKind;
  /** Active model id, when running. */
  modelId?: string;
  /** Most recently observed progress event (for UI hints during boot/download). */
  lastProgress?: ProgressEvent;
}

/** Subscription handle returned by {@link DVAIBridge.addProgressListener}. */
export interface ProgressSubscription {
  /** Detach the listener. Idempotent. */
  remove(): void;
}

/** Subscription handle returned by {@link DVAIBridge.addListener} for `"pairingRequest"`. */
export interface PairingSubscription {
  /** Detach the listener. Idempotent. */
  remove(): void;
}

/* -------------------------------------------------------------------------- */
/* v3.2 — pre-init hardware assessment                                        */
/* -------------------------------------------------------------------------- */

/**
 * Lifecycle mode the SDK would enter on `start()`. Returned by
 * {@link DVAIBridge.assessHardware}. Mirrors the kebab-case enum values
 * used on the Kotlin / Swift / TS sides so cross-platform consumers see
 * the same strings regardless of the host runtime.
 */
export type PrecheckMode = "ok" | "offload-only" | "too-weak";

/** GPU class buckets used by the heuristic. */
export type GpuClass = "none" | "integrated" | "discrete" | "apple-silicon";

/** CPU class buckets used by the heuristic. */
export type CpuClass = "low" | "mid" | "high";

/** Coarse hardware hints used by the precheck heuristic. */
export interface DeviceCapabilityHints {
  hasNpu: boolean;
  ramGb: number;
  gpuClass: GpuClass;
  cpuClass: CpuClass;
}

/**
 * v3.2 — pre-init hardware assessment.
 *
 * Returned by {@link DVAIBridge.assessHardware}. The SDK never shows
 * UI for hardware decisions — consumer apps query this and decide
 * their own UX based on `mode`:
 *
 * - `"ok"`           → device can comfortably run the model locally;
 *                      `start()` proceeds normally.
 * - `"offload-only"` → device can run but slowly (below
 *                      `OffloadConfig.minLocalCapability`); `start()`
 *                      skips the model load and routes every request
 *                      to a paired peer.
 * - `"too-weak"`     → device is below the hardware floor (3 tok/s
 *                      by default); `start()` ALSO skips the model
 *                      load. Consumers typically bail rather than
 *                      even calling `start()`.
 */
export interface HardwareAssessment {
  mode: PrecheckMode;
  /** Estimated decode tok/s for any 1–3B-class model. */
  tokPerSec: number;
  /** Human-readable explanation; safe to log + display. */
  reason: string;
  /** Underlying hints used to compute the estimate. */
  hints: DeviceCapabilityHints;
}
