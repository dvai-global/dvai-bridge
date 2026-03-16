import { CreateMLCEngine, MLCEngine, type InitProgressReport } from "@mlc-ai/web-llm";
export type { InitProgressReport };
import { setupWorker,  type SetupWorker } from "msw/browser";
import { http, HttpResponse } from "msw";
import { LicenseValidator } from "./LicenseValidator.js";

export interface DvAIConfig {
  modelId?: string;
  mockUrl?: string;
  serviceWorkerUrl?: string;
  licenseKey?: string;
  autoInit?: boolean;
}

/**
 * DvAI: Local AI Orchestration
 * Orchestrates WebLLM for local execution and MSW for intercepting API calls.
 */
export class DvAI {
  public modelId: string;
  public mockUrl: string;
  public serviceWorkerUrl: string;
  public licenseKey?: string;
  private validator: LicenseValidator;
  private engine: MLCEngine | null = null;
  private worker: SetupWorker | null = null;
  public isReady: boolean = false;

  constructor(config: DvAIConfig = {}) {
    this.modelId = config.modelId || "Qwen2.5-1.5B-Instruct-q4f16_1-MLC";
    this.mockUrl = config.mockUrl || "https://api.openai.local/v1/chat/completions";
    this.serviceWorkerUrl = config.serviceWorkerUrl || "/mockServiceWorker.js";
    this.licenseKey = config.licenseKey;
    this.validator = new LicenseValidator({ licenseKey: this.licenseKey });
  }

  /**
   * Initializes the MSW Service Worker and the WebLLM engine.
   * @param onProgress - Callback for model download progress (e.g. { text: "Loading..." })
   */
  async initialize(onProgress: (info: InitProgressReport) => void = console.log): Promise<boolean> {
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
      // 1. Setup MSW worker to intercept requests
      const handlers = [
        http.post(this.mockUrl, async ({ request }) => {
          if (!this.engine) {
            return HttpResponse.json({ error: "WebLLM engine not initialized" }, { status: 503 });
          }

          const requestBody = (await request.json()) as any;

          try {
            if (requestBody.stream) {
              const asyncChunkGenerator = (await this.engine.chat.completions.create(requestBody)) as any;
              const stream = new ReadableStream({
                async start(controller) {
                  for await (const chunk of asyncChunkGenerator) {
                    controller.enqueue(
                      new TextEncoder().encode(`data: ${JSON.stringify(chunk)}\n\n`)
                    );
                  }
                  controller.enqueue(new TextEncoder().encode("data: [DONE]\n\n"));
                  controller.close();
                },
              });
              return new HttpResponse(stream, {
                headers: {
                  "Content-Type": "text/event-stream",
                  "Cache-Control": "no-cache",
                  Connection: "keep-alive",
                },
              });
            } else {
              const response = await this.engine.chat.completions.create(requestBody);
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

      // 2. Setup WebLLM Engine
      this.engine = await CreateMLCEngine(this.modelId, {
        initProgressCallback: onProgress,
      });

      this.isReady = true;
      return true;
    } catch (error) {
      console.error("[DvAI] Failed to initialize:", error);
      throw error;
    }
  }

  /**
   * Gets the WebLLM engine instance directly if needed.
   */
  getEngine(): MLCEngine | null {
    return this.engine;
  }

  /**
   * Gets the MSW worker instance directly if needed.
   */
  getWorker(): SetupWorker | null {
    return this.worker;
  }

  /**
   * Unloads the LLM engine and stops the MSW worker to free up resources.
   */
  async unload(): Promise<void> {
    if (this.engine) {
      await this.engine.unload();
      this.engine = null;
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
