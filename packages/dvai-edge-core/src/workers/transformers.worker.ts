/**
 * Transformers.js Web Worker Entry Point
 * Runs inference inside a Web Worker to keep the main thread unblocked.
 * Supports any pipeline task (text-generation, text-to-image, ASR, etc.)
 *
 * Deploy this file to your public directory via `dvai-edge init`.
 */
// @ts-ignore - module resolved at runtime
import { pipeline, env } from "@huggingface/transformers";

let activePipeline: any = null;
let currentTask: string = "text-generation";

/**
 * Message protocol:
 * - { type: "init", pipelineTask, modelId, device } → initialize pipeline
 * - { type: "generate", requestBody } → run inference
 *     - if requestBody.raw: runs pipeline(inputs, options) directly (any modality)
 *     - else: runs text-generation with chat messages
 * - { type: "unload" } → dispose pipeline
 */
self.onmessage = async (event: MessageEvent) => {
  const { type, id, ...data } = event.data;

  try {
    switch (type) {
      case "init": {
        env.allowLocalModels = true;
        currentTask = data.pipelineTask || "text-generation";

        activePipeline = await pipeline(currentTask as any, data.modelId, {
          device: data.device,
          progress_callback: (info: any) => {
            self.postMessage({ type: "progress", id, data: info });
          },
        });
        self.postMessage({ type: "init_complete", id });
        break;
      }

      case "generate": {
        if (!activePipeline) {
          self.postMessage({ type: "error", id, error: "Pipeline not initialized" });
          return;
        }

        const { requestBody } = data;

        // Raw mode: pass inputs directly to pipeline (for any modality)
        if (requestBody.raw) {
          const result = await activePipeline(requestBody.inputs, requestBody.options);
          self.postMessage({ type: "generate_complete", id, data: result });
          return;
        }

        // Text-generation mode: use chat messages
        const { messages, max_tokens, max_completion_tokens, temperature, top_p } = requestBody;
        const maxNewTokens = max_tokens ?? max_completion_tokens ?? 256;
        const temp = temperature ?? 0.7;
        const topPVal = top_p ?? 1.0;

        const result = await activePipeline(messages, {
          max_new_tokens: maxNewTokens,
          temperature: temp,
          top_p: topPVal,
          do_sample: temp > 0,
          return_full_text: false,
        });

        self.postMessage({ type: "generate_complete", id, data: result });
        break;
      }

      case "unload": {
        if (activePipeline && typeof activePipeline.dispose === "function") {
          await activePipeline.dispose();
        }
        activePipeline = null;
        self.postMessage({ type: "unload_complete", id });
        break;
      }

      default:
        self.postMessage({ type: "error", id, error: `Unknown message type: ${type}` });
    }
  } catch (error: any) {
    self.postMessage({ type: "error", id, error: error.message });
  }
};
