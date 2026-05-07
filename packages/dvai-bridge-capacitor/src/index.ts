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
  OffloadConfig,
  PairingRequest,
  Peer,
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
  OffloadConfig,
  PairingRequest,
  Peer,
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

  /**
   * v3.0+ — distributed inference. Subscribe to one of the bridge's
   * named event channels. Currently:
   *
   *  - `"pairingRequest"`: emitted when an inbound peer requests pairing.
   *    The handler receives a {@link PairingRequest}; respond via
   *    {@link respondToPairing}. Default behaviour without a listener
   *    is to deny inbound pairing requests.
   *
   * Must be called after a successful {@link start} — the listener is
   * dispatched on the active backend plugin, which is established by
   * `start()`. Calling before `start()` throws.
   */
  async addListener(
    eventName: "pairingRequest",
    cb: (req: PairingRequest) => void,
  ): Promise<{ remove: () => Promise<void> }> {
    if (eventName !== "pairingRequest") {
      throw new Error(
        `[DVAI] addListener: unknown event name "${eventName}". Valid: "pairingRequest".`,
      );
    }
    const native = dispatch.__activePlugin();
    if (!native) {
      throw new Error("[DVAI] addListener called before start()");
    }
    return native.addListener("pairingRequest", cb);
  },

  /**
   * v3.0+ — distributed inference. Resolve a pending {@link PairingRequest}
   * received via the `"pairingRequest"` event. Pass the request `id` and
   * the user's decision; the native side records the decision and either
   * lets the pairing proceed or rejects it.
   *
   * Idempotent — responding twice to the same `requestId` resolves
   * cleanly on subsequent calls.
   */
  async respondToPairing(requestId: string, approved: boolean): Promise<void> {
    const native = dispatch.__activePlugin();
    if (!native) {
      throw new Error("[DVAI] respondToPairing called before start()");
    }
    await native.respondToPairing({ requestId, approved });
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
