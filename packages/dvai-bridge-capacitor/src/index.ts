import { dispatch } from "./dispatch.js";
import type {
  StartOptions,
  StartResult,
  StatusInfo,
  ProgressEvent,
  DownloadOptions,
  CachedModelInfo,
  CapacitorBackend,
  NativePluginInterface,
} from "./types.js";

export type {
  CapacitorBackend,
  StartOptions,
  StartResult,
  StatusInfo,
  ProgressEvent,
  DownloadOptions,
  CachedModelInfo,
  NativePluginInterface,
};

export const DVAIBridge = {
  /** Start the embedded HTTP server with the chosen backend. Returns the URL. */
  async start(opts: StartOptions): Promise<StartResult> {
    return dispatch.start(opts);
  },

  /** Stop the server and unload the model. Idempotent. */
  async stop(): Promise<void> {
    return dispatch.stop();
  },

  /** Status snapshot — useful for UI reactivity. */
  async status(): Promise<StatusInfo> {
    return dispatch.status();
  },

  /** Subscribe to load/progress events. */
  async addProgressListener(
    cb: (e: ProgressEvent) => void,
  ): Promise<{ remove: () => Promise<void> }> {
    const native = dispatch.__activePlugin();
    if (!native) {
      throw new Error("[DVAI] addProgressListener called before start()");
    }
    return native.addListener("progress", cb);
  },

  /** Resumable, checksum-verified, app-data-cached download. */
  async downloadModel(opts: DownloadOptions): Promise<{ path: string; cached: boolean }> {
    const native = await modelManagementPlugin();
    return native.downloadModel(opts);
  },

  async listCachedModels(): Promise<CachedModelInfo[]> {
    const native = await modelManagementPlugin();
    const result = await native.listCachedModels();
    return result.models;
  },

  async deleteCachedModel(filename: string): Promise<void> {
    const native = await modelManagementPlugin();
    await native.deleteCachedModel({ filename });
  },

  async cacheDir(): Promise<string> {
    const native = await modelManagementPlugin();
    const result = await native.cacheDir();
    return result.path;
  },
};

/**
 * Resolve the plugin that owns model-management methods (downloadModel,
 * listCachedModels, deleteCachedModel, cacheDir). In Phase 1, only the
 * `llama` backend implements these — `foundation` rejects (Apple manages
 * models internally) and `mediapipe` rejects (developer-managed paths).
 *
 * If a non-llama plugin is currently active, model management still routes
 * to the llama plugin (caller can install + use it without `start()`).
 * The native side may reject if the plugin isn't installed; the resulting
 * Capacitor "plugin not implemented" error is the right surface.
 */
async function modelManagementPlugin(): Promise<NativePluginInterface> {
  const active = dispatch.__activePlugin();
  if (active) return active;
  const { registerPlugin } = await import("@capacitor/core");
  return registerPlugin<NativePluginInterface>("DVAIBridgeLlama");
}
