import { registerPlugin } from "@capacitor/core";
import type {
  CapacitorBackend,
  NativePluginInterface,
  StartOptions,
  StartResult,
  StatusInfo,
} from "./types.js";

const PLUGIN_NAME_BY_BACKEND: Record<CapacitorBackend, string> = {
  llama: "DVAIBridgeLlama",
  foundation: "DVAIBridgeFoundation",
  mediapipe: "DVAIBridgeMediaPipe",
};

let activePlugin: NativePluginInterface | null = null;
let activeBackend: CapacitorBackend | null = null;

function pluginFor(backend: CapacitorBackend): NativePluginInterface {
  const name = PLUGIN_NAME_BY_BACKEND[backend];
  return registerPlugin<NativePluginInterface>(name);
}

function isPluginNotImplementedError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return /not implemented|not available|UNIMPLEMENTED/i.test(msg);
}

export const dispatch = {
  async start(opts: StartOptions): Promise<StartResult> {
    const native = pluginFor(opts.backend);
    try {
      const result = await native.start(opts);
      activePlugin = native;
      activeBackend = opts.backend;
      return result;
    } catch (err) {
      if (isPluginNotImplementedError(err)) {
        throw new Error(
          `[DVAI] Backend "${opts.backend}" selected but the corresponding plugin is not installed. ` +
            `Run: npm install @dvai-bridge/capacitor-${opts.backend} && npx cap sync`,
        );
      }
      throw err;
    }
  },

  async stop(): Promise<void> {
    if (!activePlugin) return;
    try {
      await activePlugin.stop();
    } finally {
      activePlugin = null;
      activeBackend = null;
    }
  },

  async status(): Promise<StatusInfo> {
    if (!activePlugin) return { running: false };
    return activePlugin.status();
  },

  __reset(): void {
    activePlugin = null;
    activeBackend = null;
  },

  __activePlugin(): NativePluginInterface | null {
    return activePlugin;
  },
};
