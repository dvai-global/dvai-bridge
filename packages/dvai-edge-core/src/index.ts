import { setupWorker, type SetupWorker } from "msw/browser";
import { http, HttpResponse } from "msw";
import { LicenseValidator } from "./LicenseValidator.js";

// Re-export types from backends
export type { TransformersProgressInfo } from "./TransformersBackend.js";
export { detectWebGPU } from "./TransformersBackend.js";

// Re-export InitProgressReport from web-llm for backward compatibility
export type { InitProgressReport } from "@mlc-ai/web-llm";

export type BackendType = "webllm" | "transformers";
export type DeviceType = "webgpu" | "cpu" | "auto";
export type { PipelineTask } from "./TransformersBackend.js";

export interface DvAIConfig {
  /** The model ID for web-llm backend. Default: "Qwen2.5-1.5B-Instruct-q4f16_1-MLC" */
  modelId?: string;
  /** The backend engine to use. Default: "webllm" */
  backend?: BackendType;
  /** HuggingFace model ID for Transformers.js backend. Default: "Xenova/Qwen2.5-0.5B-Instruct" */
  transformersModelId?: string;
  /** Pipeline task for Transformers.js (e.g. "text-generation", "text-to-image", "automatic-speech-recognition"). Default: "text-generation" */
  pipelineTask?: string;
  /** Device for Transformers.js - "webgpu", "cpu", or "auto" (detect). Default: "auto" */
  device?: DeviceType;
  /** Generation timeout in ms. Default: 60000 (60s) */
  generationTimeout?: number;
  /** Maximum consecutive blank chunks before aborting stream. Default: 20 */
  maxBlankChunks?: number;
  /** Mock URL for MSW interception. Default: "https://api.openai.local/v1/chat/completions" */
  mockUrl?: string;
  /** Path to the MSW service worker script. Default: "/mockServiceWorker.js" */
  serviceWorkerUrl?: string;
  /** URL to the WebLLM worker script (for offloading inference). Default: "/dvai-webllm.worker.js" */
  webllmWorkerUrl?: string;
  /** URL to the Transformers.js worker script (for offloading inference). Default: "/dvai-transformers.worker.js" */
  transformersWorkerUrl?: string;
  /** License key for production use. */
  licenseKey?: string;
  /** Auto-initialize on creation (React/Vanilla). Default: true */
  autoInit?: boolean;
}

/**
 * DvAI: Local AI Orchestration
 * Orchestrates WebLLM or Transformers.js for local execution
 * and MSW for intercepting API calls with an OpenAI-compatible endpoint.
 */
export class DvAI {
  public modelId: string;
  public mockUrl: string;
  public serviceWorkerUrl: string;
  public licenseKey?: string;
  public backend: BackendType;
  public transformersModelId: string;
  public pipelineTask: string;
  public device: DeviceType;
  public generationTimeout: number;
  public maxBlankChunks: number;
  public webllmWorkerUrl: string;
  public transformersWorkerUrl: string;

  private validator: LicenseValidator;
  private backendInstance: any = null; // WebLLMBackend | TransformersBackend
  private worker: SetupWorker | null = null;
  public isReady: boolean = false;

  constructor(config: DvAIConfig = {}) {
    this.modelId = config.modelId || "Qwen2.5-1.5B-Instruct-q4f16_1-MLC";
    this.backend = config.backend || "webllm";
    this.transformersModelId = config.transformersModelId || "Xenova/Qwen2.5-0.5B-Instruct";
    this.pipelineTask = config.pipelineTask || "text-generation";
    this.device = config.device || "auto";
    this.generationTimeout = config.generationTimeout ?? 60000;
    this.maxBlankChunks = config.maxBlankChunks ?? 20;
    this.webllmWorkerUrl = config.webllmWorkerUrl || "/dvai-webllm.worker.js";
    this.transformersWorkerUrl = config.transformersWorkerUrl || "/dvai-transformers.worker.js";
    this.mockUrl = config.mockUrl || "https://api.openai.local/v1/chat/completions";
    this.serviceWorkerUrl = config.serviceWorkerUrl || "/mockServiceWorker.js";
    this.licenseKey = config.licenseKey;
    this.validator = new LicenseValidator({ licenseKey: this.licenseKey });
  }

  /**
   * Returns the active backend type.
   */
  getActiveBackend(): BackendType {
    return this.backend;
  }

  /**
   * Initializes the MSW Service Worker and the selected backend engine.
   * @param onProgress - Callback for model download progress
   */
  async initialize(onProgress: (info: any) => void = console.log): Promise<boolean> {
    if (this.isReady) return true;

    // 0. Validate License for Commercial/Production use
    await this.validator.validate();

    // 0.1 Verify Service Worker Reachability (Quality of Life)
    try {
      const swRes = await fetch(this.serviceWorkerUrl, { method: "HEAD" });
      if (!swRes.ok) {
        console.warn(
          `[DvAI] Warning: Service Worker not found at "${this.serviceWorkerUrl}". ` +
          `Please run "dvai-edge init" or "npx msw init <public_dir>" to generate it.`
        );
      }
    } catch (e) {
      console.warn(`[DvAI] Could not verify Service Worker existence at "${this.serviceWorkerUrl}".`);
    }

    try {
      // 1. Initialize the selected backend (lazy import)
      await this.initializeBackend(onProgress);

      // 2. Setup MSW worker to intercept requests
      const handlers = [
        http.post(this.mockUrl, async ({ request }) => {
          if (!this.backendInstance) {
            return HttpResponse.json({ error: "AI engine not initialized" }, { status: 503 });
          }

          const requestBody = (await request.json()) as any;

          try {
            if (requestBody.stream) {
              const stream = this.backendInstance.createStreamingResponse(requestBody);
              return new HttpResponse(stream, {
                headers: {
                  "Content-Type": "text/event-stream",
                  "Cache-Control": "no-cache",
                  Connection: "keep-alive",
                },
              });
            } else {
              const response = await this.backendInstance.chatCompletion(requestBody);
              return HttpResponse.json(response);
            }
          } catch (error: any) {
            console.error("[DvAI] Error processing request:", error);
            return HttpResponse.json({ error: error.message }, { status: 500 });
          }
        }),
      ];

      this.worker = setupWorker(...handlers);
      await this.worker.start({
        onUnhandledRequest: "bypass",
        serviceWorker: {
          url: this.serviceWorkerUrl,
        },
      });

      this.isReady = true;
      return true;
    } catch (error) {
      console.error("[DvAI] Failed to initialize:", error);
      throw error;
    }
  }

  /**
   * Lazy-imports and initializes the selected backend.
   */
  private async initializeBackend(onProgress: (info: any) => void): Promise<void> {
    if (this.backend === "transformers") {
      let TransformersBackend: any;
      try {
        const mod = await import("./TransformersBackend.js");
        TransformersBackend = mod.TransformersBackend;
      } catch {
        throw new Error(
          '[DvAI] Transformers.js backend selected but "@huggingface/transformers" is not installed.\n' +
          'Install it with: npm install @huggingface/transformers'
        );
      }
      const backend = new TransformersBackend({
        modelId: this.transformersModelId,
        device: this.device,
        generationTimeout: this.generationTimeout,
        workerUrl: this.transformersWorkerUrl,
        pipelineTask: this.pipelineTask,
      });
      await backend.initialize(onProgress);
      this.backendInstance = backend;
      console.log(`[DvAI] Transformers.js backend ready (task: ${this.pipelineTask}, device: ${backend.getResolvedDevice()}, worker: ${backend.isWorkerBased()})`);
    } else {
      let WebLLMBackend: any;
      try {
        const mod = await import("./WebLLMBackend.js");
        WebLLMBackend = mod.WebLLMBackend;
      } catch {
        throw new Error(
          '[DvAI] WebLLM backend selected but "@mlc-ai/web-llm" is not installed.\n' +
          'Install it with: npm install @mlc-ai/web-llm'
        );
      }
      const backend = new WebLLMBackend({
        modelId: this.modelId,
        generationTimeout: this.generationTimeout,
        maxBlankChunks: this.maxBlankChunks,
        workerUrl: this.webllmWorkerUrl,
      });
      await backend.initialize(onProgress);
      this.backendInstance = backend;
      console.log(`[DvAI] WebLLM backend ready (worker: ${backend.isWorkerBased()})`);
    }
  }

  /**
   * Gets the underlying engine instance directly.
   * - For WebLLM: returns the MLCEngine
   * - For Transformers.js: returns the pipeline
   */
  getEngine(): any {
    if (!this.backendInstance) return null;
    if (this.backend === "webllm") {
      return this.backendInstance.getEngine?.() ?? null;
    }
    return this.backendInstance.getPipeline?.() ?? null;
  }

  /**
   * Gets the MSW worker instance directly if needed.
   */
  getWorker(): SetupWorker | null {
    return this.worker;
  }

  /**
   * Perform a direct chat completion (bypasses MSW, calls backend directly).
   * Useful for programmatic usage without going through the fetch mock.
   */
  async chatCompletion(requestBody: any): Promise<any> {
    if (!this.backendInstance) throw new Error("[DvAI] Backend not initialized. Call initialize() first.");
    return this.backendInstance.chatCompletion(requestBody);
  }

  /**
   * Run the pipeline directly (Transformers.js only).
   * Use this for non-text tasks like text-to-image, ASR, text-to-speech, etc.
   * @param inputs - Input data appropriate for the pipeline task
   * @param options - Pipeline-specific options
   */
  async runPipeline(inputs: any, options?: Record<string, any>): Promise<any> {
    if (!this.backendInstance) throw new Error("[DvAI] Backend not initialized. Call initialize() first.");
    if (this.backend !== "transformers" || !this.backendInstance.runPipeline) {
      throw new Error("[DvAI] runPipeline() is only available with the Transformers.js backend.");
    }
    return this.backendInstance.runPipeline(inputs, options);
  }

  /**
   * Unloads the AI engine and stops the MSW worker to free up resources.
   */
  async unload(): Promise<void> {
    if (this.backendInstance) {
      await this.backendInstance.unload();
      this.backendInstance = null;
    }

    if (this.worker) {
      this.worker.stop();
      this.worker = null;
    }

    this.isReady = false;
    console.log("[DvAI] Unloaded model and worker.");
  }
}

// Export a singleton instance by default, or the class for advanced usage
export const dvai: DvAI = new DvAI();
