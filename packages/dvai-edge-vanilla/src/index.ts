import { dvai, DvAI, type DvAIConfig, type BackendType } from "@dvai-edge/core";

export type { DvAIConfig, BackendType } from "@dvai-edge/core";

export interface VanillaState {
  isReady: boolean;
  progress: string;
  mockUrl: string;
  modelId: string;
  backend: BackendType;
}

export type VanillaListener = (state: VanillaState) => void;

/**
 * VanillaDvAI: A simple wrapper for dvai-edge-core to be used in vanilla JS applications.
 */
export class VanillaDvAI {
  private core: DvAI;
  private isReady: boolean = false;
  private progressText: string = "";
  private mockUrl: string;
  private modelId: string;
  private backend: BackendType;
  private listeners: Set<VanillaListener> = new Set();

  constructor(config: DvAIConfig = {}) {
    this.core = dvai; // Default to singleton
    // Apply config to singleton
    if (Object.keys(config).length > 0) {
      if (config.modelId) this.core.modelId = config.modelId;
      if (config.mockUrl) this.core.mockUrl = config.mockUrl;
      if (config.serviceWorkerUrl) this.core.serviceWorkerUrl = config.serviceWorkerUrl;
      if (config.backend) this.core.backend = config.backend;
      if (config.transformersModelId) this.core.transformersModelId = config.transformersModelId;
      if (config.device) this.core.device = config.device;
      if (config.generationTimeout !== undefined) this.core.generationTimeout = config.generationTimeout;
      if (config.maxBlankChunks !== undefined) this.core.maxBlankChunks = config.maxBlankChunks;
      if (config.pipelineTask) this.core.pipelineTask = config.pipelineTask;
      if (config.webllmWorkerUrl) this.core.webllmWorkerUrl = config.webllmWorkerUrl;
      if (config.transformersWorkerUrl) this.core.transformersWorkerUrl = config.transformersWorkerUrl;
    }

    this.mockUrl = this.core.mockUrl;
    this.modelId = this.core.backend === "transformers" ? this.core.transformersModelId : this.core.modelId;
    this.backend = this.core.backend;
  }

  /**
   * Initializes the AI engine.
   */
  async initialize(): Promise<void> {
    await this.core.initialize((progress) => {
      this.progressText = progress.text;
      this.isReady = this.core.isReady;
      this.notifyListeners();
    });
    this.isReady = this.core.isReady;
    this.notifyListeners();
  }

  /**
   * Unloads the AI engine and worker.
   */
  async unload(): Promise<void> {
    await this.core.unload();
    this.isReady = this.core.isReady;
    this.progressText = "";
    this.notifyListeners();
  }

  /**
   * Subscribes to state changes.
   * @param listener - Callback function receiving the current state.
   * @returns A function to unsubscribe.
   */
  subscribe(listener: VanillaListener): () => void {
    this.listeners.add(listener);
    // Send initial state immediately
    listener(this.getState());
    return () => {
      this.listeners.delete(listener);
    };
  }

  private notifyListeners(): void {
    const state = this.getState();
    this.listeners.forEach((listener) => listener(state));
  }

  /**
   * Returns the current state.
   */
  getState(): VanillaState {
    return {
      isReady: this.isReady,
      progress: this.progressText,
      mockUrl: this.mockUrl,
      modelId: this.modelId,
      backend: this.backend,
    };
  }
}

// Attach to global window object for browser `<script>` usage
if (typeof window !== "undefined") {
  (window as any).VanillaDvAI = VanillaDvAI;
}

export default VanillaDvAI;
