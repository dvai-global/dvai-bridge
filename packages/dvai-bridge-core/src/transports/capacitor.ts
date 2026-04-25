import type { HandlerContext } from "../handlers/context.js";
import type { Transport, TransportStartResult } from "./types.js";

export interface CapacitorTransportOptions {
  capacitorBackend: "llama" | "foundation" | "mediapipe";
  nativeModelPath?: string;
  nativeMmprojPath?: string;
  nativeGpuLayers?: number;
  nativeContextSize?: number;
  nativeThreads?: number;
  nativeEmbeddingMode?: boolean;
  httpBasePort: number;
  httpMaxPortAttempts: number;
  corsOrigin: string | string[];
  autoUnloadOnLowMemory?: boolean;
  logLevel?: "silent" | "info" | "debug";
}

export class CapacitorTransport implements Transport {
  readonly kind = "capacitor" as const;

  constructor(private readonly opts: CapacitorTransportOptions) {}

  async start(_ctx: HandlerContext): Promise<TransportStartResult> {
    const { DVAIBridge } = await import("@dvai-bridge/capacitor");
    const result = await DVAIBridge.start({
      backend: this.opts.capacitorBackend,
      modelPath: this.opts.nativeModelPath,
      mmprojPath: this.opts.nativeMmprojPath,
      gpuLayers: this.opts.nativeGpuLayers,
      contextSize: this.opts.nativeContextSize,
      threads: this.opts.nativeThreads,
      embeddingMode: this.opts.nativeEmbeddingMode,
      httpBasePort: this.opts.httpBasePort,
      httpMaxPortAttempts: this.opts.httpMaxPortAttempts,
      corsOrigin: this.opts.corsOrigin,
      autoUnloadOnLowMemory: this.opts.autoUnloadOnLowMemory,
      logLevel: this.opts.logLevel,
    });
    return { baseUrl: result.baseUrl, port: result.port };
  }

  async stop(): Promise<void> {
    const { DVAIBridge } = await import("@dvai-bridge/capacitor");
    await DVAIBridge.stop();
  }
}
