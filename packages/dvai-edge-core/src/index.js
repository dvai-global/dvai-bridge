import { CreateMLCEngine } from "@mlc-ai/web-llm";
import { setupWorker } from "msw/browser";
import { http, HttpResponse } from "msw";
import { LicenseValidator } from "./LicenseValidator.js";

export class DvAI {
  constructor(config = {}) {
    this.modelId = config.modelId || "Qwen2.5-1.5B-Instruct-q4f16_1-MLC";
    this.mockUrl = config.mockUrl || "https://api.openai.local/v1/chat/completions";
    this.serviceWorkerUrl = config.serviceWorkerUrl || "/mockServiceWorker.js";
    this.licenseKey = config.licenseKey;
    this.validator = new LicenseValidator({ licenseKey: this.licenseKey });
    this.engine = null;
    this.worker = null;
    this.isReady = false;
  }

  /**
   * Initializes the MSW Service Worker and the WebLLM engine.
   * @param {function} onProgress - Callback for model download progress (e.g. { text: "Loading..." })
   */
  async initialize(onProgress = console.log) {
    if (this.isReady) return;

    // 0. Validate License for Commercial/Production use
    await this.validator.validate();

    try {
      // 1. Setup MSW worker to intercept requests
      const handlers = [
        http.post(this.mockUrl, async ({ request }) => {
          if (!this.engine) {
            return HttpResponse.json({ error: "WebLLM engine not initialized" }, { status: 503 });
          }

          const requestBody = await request.json();

          try {
            if (requestBody.stream) {
              const asyncChunkGenerator = await this.engine.chat.completions.create(requestBody);
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
          } catch (error) {
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
  getEngine() {
    return this.engine;
  }

  /**
   * Gets the MSW worker instance directly if needed.
   */
  getWorker() {
    return this.worker;
  }
}

// Export a singleton instance by default, or the class for advanced usage
export const dvai = new DvAI();
