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
