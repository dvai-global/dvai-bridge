/**
 * @dvai-bridge/capacitor — public type definitions.
 * These types are also imported by backend plugin packages
 * (capacitor-llama, capacitor-foundation, capacitor-mediapipe)
 * to keep the JS↔native contract consistent.
 */

export type CapacitorBackend = "llama" | "foundation" | "mediapipe";

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
}
