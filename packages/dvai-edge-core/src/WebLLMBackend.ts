/**
 * WebLLMBackend: Wraps @mlc-ai/web-llm with robustness improvements.
 * - Runs inference in a Web Worker to keep main thread unblocked
 * - Falls back to main-thread engine if worker URL is not available
 * - Blank-chunk detection to abort runaway streams
 * - Generation timeout to prevent infinite loops
 * - finish_reason checks to properly terminate streams
 * - Engine state cleanup after failures
 */

export interface WebLLMBackendConfig {
  modelId: string;
  generationTimeout: number;
  maxBlankChunks: number;
  workerUrl?: string;
  onProgress?: (info: any) => void;
}

export class WebLLMBackend {
  private engine: any = null; // MLCEngine | WebWorkerMLCEngine
  private modelId: string;
  private generationTimeout: number;
  private maxBlankChunks: number;
  private workerUrl?: string;
  private usingWorker: boolean = false;

  constructor(config: WebLLMBackendConfig) {
    this.modelId = config.modelId;
    this.generationTimeout = config.generationTimeout;
    this.maxBlankChunks = config.maxBlankChunks;
    this.workerUrl = config.workerUrl;
  }

  async initialize(onProgress?: (info: any) => void): Promise<void> {
    const webllm = await import("@mlc-ai/web-llm");

    // Try worker-based engine first (fully offloads inference from main thread)
    if (this.workerUrl && typeof Worker !== "undefined") {
      try {
        const worker = new Worker(this.workerUrl, { type: "module" });
        this.engine = new webllm.WebWorkerMLCEngine(worker, {
          initProgressCallback: onProgress,
        });
        await this.engine.reload(this.modelId);
        this.usingWorker = true;
        console.log("[DvAI/WebLLM] Initialized with Web Worker (main thread unblocked)");
        return;
      } catch (err) {
        console.warn("[DvAI/WebLLM] Worker initialization failed, falling back to main thread:", err);
      }
    }

    // Fallback: main-thread engine (WebGPU compute is still async/non-blocking)
    this.engine = await webllm.CreateMLCEngine(this.modelId, {
      initProgressCallback: onProgress,
    });
    this.usingWorker = false;
    console.log("[DvAI/WebLLM] Initialized on main thread (WebGPU compute is async)");
  }

  isWorkerBased(): boolean {
    return this.usingWorker;
  }

  getEngine(): any {
    return this.engine;
  }

  /**
   * Non-streaming chat completion with timeout protection.
   */
  async chatCompletion(requestBody: any): Promise<any> {
    if (!this.engine) throw new Error("WebLLM engine not initialized");

    const result: any = await this.withTimeout(
      this.engine.chat.completions.create({
        ...requestBody,
        stream: false,
      }),
      this.generationTimeout
    );

    // Validate response has actual content
    const content = result?.choices?.[0]?.message?.content;
    if (content === undefined || content === null || content === "") {
      console.warn("[DvAI/WebLLM] Warning: Engine returned blank content, attempting engine reset.");
      try { await this.engine.resetChat(); } catch (_) { /* best effort */ }
      throw new Error("WebLLM engine returned blank content. The engine state has been reset — please retry.");
    }

    return result;
  }

  /**
   * Streaming chat completion with blank-chunk detection, timeout, and finish_reason termination.
   * Returns a ReadableStream of SSE-formatted data.
   */
  createStreamingResponse(requestBody: any): ReadableStream<Uint8Array> {
    const engine = this.engine;
    if (!engine) throw new Error("WebLLM engine not initialized");
    const maxBlankChunks = this.maxBlankChunks;
    const generationTimeout = this.generationTimeout;

    return new ReadableStream<Uint8Array>({
      async start(controller) {
        let consecutiveBlanks = 0;
        let timeoutId: ReturnType<typeof setTimeout> | null = null;

        try {
          const asyncChunkGenerator = (await engine.chat.completions.create({
            ...requestBody,
            stream: true,
          })) as unknown as AsyncIterable<any>;

          // Set overall generation timeout
          const timeoutPromise = new Promise<never>((_, reject) => {
            timeoutId = setTimeout(() => {
              reject(new Error(`Generation timed out after ${generationTimeout}ms`));
            }, generationTimeout);
          });

          const streamPromise = (async () => {
            for await (const chunk of asyncChunkGenerator) {
              const delta = chunk?.choices?.[0]?.delta;
              const finishReason = chunk?.choices?.[0]?.finish_reason;

              // Check for blank chunks
              if (!delta?.content && delta?.content !== undefined) {
                consecutiveBlanks++;
                if (consecutiveBlanks >= maxBlankChunks) {
                  console.warn(`[DvAI/WebLLM] ${maxBlankChunks} consecutive blank chunks detected, aborting stream.`);
                  try { engine.interruptGenerate(); } catch (_) { /* best effort */ }
                  try { await engine.resetChat(); } catch (_) { /* best effort */ }
                  controller.enqueue(
                    new TextEncoder().encode(
                      `data: ${JSON.stringify({ error: "Stream aborted: too many blank chunks" })}\n\n`
                    )
                  );
                  break;
                }
              } else {
                consecutiveBlanks = 0;
              }

              // Emit the chunk
              controller.enqueue(
                new TextEncoder().encode(`data: ${JSON.stringify(chunk)}\n\n`)
              );

              // Check if generation is complete
              if (finishReason === "stop" || finishReason === "length") {
                break;
              }
            }
          })();

          // Race: stream vs timeout
          await Promise.race([streamPromise, timeoutPromise]);
        } catch (error: any) {
          console.error("[DvAI/WebLLM] Stream error:", error.message);
          // Try to interrupt and reset on failure
          try { engine.interruptGenerate(); } catch (_) { /* best effort */ }
          try { await engine.resetChat(); } catch (_) { /* best effort */ }
          controller.enqueue(
            new TextEncoder().encode(
              `data: ${JSON.stringify({ error: error.message })}\n\n`
            )
          );
        } finally {
          if (timeoutId) clearTimeout(timeoutId);
          controller.enqueue(new TextEncoder().encode("data: [DONE]\n\n"));
          controller.close();
        }
      },
    });
  }

  async unload(): Promise<void> {
    if (this.engine) {
      await this.engine.unload();
      this.engine = null;
    }
  }

  /** Wraps a promise with a timeout. */
  private withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Generation timed out after ${ms}ms`)), ms);
      promise
        .then((val) => { clearTimeout(timer); resolve(val); })
        .catch((err) => { clearTimeout(timer); reject(err); });
    });
  }
}
