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
    const native =
      dispatch.__activePlugin() ?? (await import("@capacitor/core")).registerPlugin("DVAIBridgeLlama");
    return (native as any).downloadModel(opts);
  },

  async listCachedModels(): Promise<CachedModelInfo[]> {
    const native =
      dispatch.__activePlugin() ?? (await import("@capacitor/core")).registerPlugin("DVAIBridgeLlama");
    const result = await (native as any).listCachedModels();
    return result.models;
  },

  async deleteCachedModel(filename: string): Promise<void> {
    const native =
      dispatch.__activePlugin() ?? (await import("@capacitor/core")).registerPlugin("DVAIBridgeLlama");
    await (native as any).deleteCachedModel({ filename });
  },

  async cacheDir(): Promise<string> {
    const native =
      dispatch.__activePlugin() ?? (await import("@capacitor/core")).registerPlugin("DVAIBridgeLlama");
    const result = await (native as any).cacheDir();
    return result.path;
  },
};
