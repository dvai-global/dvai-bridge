/**
 * Transformers.js Web Worker Entry Point
 * Runs inference inside a Web Worker to keep the main thread unblocked.
 * Supports any pipeline task (text-generation, text-to-image, ASR, etc.)
 *
 * Deploy this file to your public directory via `dvai-edge init`.
 */
// @ts-ignore - module resolved at runtime
import { pipeline, env } from "@huggingface/transformers";

/**
 * Aggressive content flattening to satisfy Jinja2 templates (like Llama 3)
 * that expect 'content' to be a string and use filters like '| trim'.
 */
function flattenContent(content: any): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((c) => flattenContent(c)).join("");
  }
  if (content && typeof content === "object") {
    return content.text || content.content || JSON.stringify(content);
  }
  return String(content || "");
}

// Disable internal ONNX Runtime proxy (prevents nested worker spawning)
// and set numThreads to 1 to ensure single-thread WASM execution within our worker.
// Try multiple access paths for env.backends — the layout varies across
// Transformers.js versions (v3 vs v4) and ONNX Runtime versions.
try {
  if ((env as any).backends?.onnx?.wasm) {
    (env as any).backends.onnx.wasm.proxy = false;
    (env as any).backends.onnx.wasm.numThreads = 1;
  }
} catch { /* env path not available in this version */ }

// Also try the onnxruntime-web env directly (ort.env.wasm)
try {
  const ort = (globalThis as any).ort ?? (env as any).ort;
  if (ort?.env?.wasm) {
    ort.env.wasm.proxy = false;
    ort.env.wasm.numThreads = 1;
  }
} catch { /* ort not available */ }

// Force use of remote models (CDN)
env.allowLocalModels = false;
env.allowRemoteModels = true;
env.remoteHost = "https://huggingface.co";
env.remotePathTemplate = "{model}/resolve/{revision}/";

let activePipeline: any = null;
let activeModelId: string = "";
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
        currentTask = data.pipelineTask || "text-generation";
        activeModelId = data.modelId;
        const device = data.device === "cpu" ? "wasm" : data.device;

        activePipeline = await pipeline(currentTask as any, data.modelId, {
          device: device,
          progress_callback: (info: any) => {
            self.postMessage({ type: "progress", id, data: info });
          },
          dtype: data.dtype,
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
        const { messages: rawMessages, max_tokens, max_completion_tokens, temperature, top_p } = requestBody;
        const maxNewTokens = max_tokens ?? max_completion_tokens ?? 256;
        const temp = temperature ?? 0.7;
        const topPVal = top_p ?? 1.0;

        // Aggressive sanitization: ensure content is ALWAYS a string
        const messages = (rawMessages || []).map((m: any) => ({
          ...m,
          content: flattenContent(m.content)
        }));

        console.log("[DvAI/Worker] Sanitized messages for Jinja:", messages);

        const options: any = {
          max_new_tokens: maxNewTokens,
          temperature: temp,
          top_p: topPVal,
          do_sample: temp > 0,
          return_full_text: false,
        };

        const result = await activePipeline(messages, options);

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
