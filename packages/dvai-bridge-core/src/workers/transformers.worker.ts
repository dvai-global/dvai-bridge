/**
 * Transformers.js Web Worker Entry Point
 *
 * Runs inference inside a Web Worker to keep the main thread unblocked.
 * Supports any pipeline task (text-generation, text-to-image, ASR,
 * feature-extraction, etc.) through the default `pipeline()` factory.
 *
 * Two loader paths, chosen by the init message:
 *
 *   1. Default / generic: worker calls `pipeline(task, modelId, { device,
 *      dtype, progress_callback })`. This is what you want for 99% of
 *      transformers.js models — text generation, embeddings, classifiers,
 *      most image tasks, etc. No per-model config required.
 *
 *   2. Declarative model+processor: when the init message carries
 *      `modelClass` (and optionally `processorClass`), the worker loads
 *      the named classes directly via `.from_pretrained(modelId)` and
 *      wraps them in a generic pipeline-shaped callable. Use this for
 *      multimodal checkpoints that the `pipeline()` factory doesn't
 *      cover (e.g., Gemma-4, Llava, Idefics — anything with a processor
 *      that takes audio/image positional args). The host app may also
 *      pass `disableEncoders: ['vision_encoder', ...]` to null specific
 *      submodules after load and reclaim their memory when unused.
 *
 * Both paths produce the same callable shape, so chat completion,
 * streaming, embeddings, and `runPipeline` all work uniformly downstream.
 *
 * Audio bytes travel from main thread → worker via `postMessage` structured
 * clone, NOT JSON, so `Float32Array` survives the hop intact. Host apps
 * should feed audio as `{ type: 'audio', data: Float32Array }` content
 * parts on the last user message; the worker extracts them before calling
 * the processor.
 *
 * Deploy this file to your public directory via `dvai-bridge init`.
 */
// @ts-ignore - module resolved at runtime
import * as transformers from "@huggingface/transformers";
import {
	buildMultimodalCallable,
	disableModelEncoders,
} from "../multimodalCallable";

const { pipeline, env, TextStreamer } = transformers as any;

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
 * Convert a Transformers.js Tensor (or plain array) into a nested number[][].
 * Handles both single-input and batched feature-extraction outputs.
 */
function tensorToArray(t: any): number[][] {
  if (!t) return [];
  // Already a plain array (batched or single)
  if (Array.isArray(t)) {
    if (t.length > 0 && Array.isArray(t[0])) return t as number[][];
    return [t as number[]];
  }
  // Transformers.js Tensor: has .tolist() or .data + .dims
  if (typeof t.tolist === "function") {
    const arr = t.tolist();
    if (Array.isArray(arr) && arr.length > 0 && Array.isArray(arr[0])) return arr;
    return [arr];
  }
  if (t.data && t.dims) {
    const [batch, hidden] = t.dims.length === 2 ? t.dims : [1, t.dims[t.dims.length - 1]];
    const flat = Array.from(t.data as Iterable<number>);
    const out: number[][] = [];
    for (let i = 0; i < batch; i++) {
      out.push(flat.slice(i * hidden, (i + 1) * hidden));
    }
    return out;
  }
  return [];
}

/**
 * Message protocol:
 * - { type: "init", pipelineTask, modelId, device, dtype,
 *     modelClass?, processorClass?, disableEncoders? }
 *   → initialize pipeline. When `modelClass` is present, takes the
 *     declarative model+processor path; otherwise defaults to pipeline().
 * - { type: "generate", requestBody } → run inference (non-streaming)
 *     - if requestBody.raw: runs pipeline(inputs, options) directly (any modality)
 *     - else: runs text-generation with chat messages
 * - { type: "generate_stream", requestBody } → stream text generation token-by-token
 *     - emits { type: "stream_chunk", id, text } for each decoded text chunk
 *     - emits { type: "stream_complete", id } when done
 * - { type: "embed", inputs } → run feature-extraction pipeline and return embeddings
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

        if (data.modelClass) {
          // Declarative multimodal path. Host app tells us which classes
          // to use; dvai-bridge stays model-agnostic. This is how we
          // support Gemma-4 / Llava / Idefics / etc. in the worker without
          // hardcoding any of them.
          const ModelClass = (transformers as any)[data.modelClass];
          if (!ModelClass) {
            throw new Error(
              `Worker init: transformers.js has no export named "${data.modelClass}". ` +
                `Check your modelClass config (case-sensitive).`,
            );
          }
          const processorName = data.processorClass || "AutoProcessor";
          const ProcessorClass = (transformers as any)[processorName];
          if (!ProcessorClass) {
            throw new Error(
              `Worker init: transformers.js has no export named "${processorName}". ` +
                `Check your processorClass config (default: AutoProcessor).`,
            );
          }

          const processor = await ProcessorClass.from_pretrained(data.modelId, {
            progress_callback: (info: any) => {
              self.postMessage({ type: "progress", id, data: info });
            },
          });
          const model = await ModelClass.from_pretrained(data.modelId, {
            dtype: data.dtype,
            device: device,
            progress_callback: (info: any) => {
              self.postMessage({ type: "progress", id, data: info });
            },
          });

          // Declarative encoder disabling — host app specifies which
          // submodules to null (e.g., ['vision_encoder'] for voice-only apps
          // to reclaim ~99 MB). Unknown/absent fields are silently ignored.
          disableModelEncoders(model, data.disableEncoders);

          activePipeline = buildMultimodalCallable(model, processor);
          self.postMessage({ type: "init_complete", id });
          break;
        }

        // Default: generic pipeline() for all other models/tasks.
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

        const { messages, options } = buildTextGenArgs(requestBody);
        const result = await activePipeline(messages, options);
        self.postMessage({ type: "generate_complete", id, data: result });
        break;
      }

      case "generate_stream": {
        if (!activePipeline) {
          self.postMessage({ type: "error", id, error: "Pipeline not initialized" });
          return;
        }

        const { messages, options } = buildTextGenArgs(data.requestBody);

        // Attach a TextStreamer that posts each decoded text chunk back to the main thread.
        // skip_prompt: don't emit the rendered prompt; skip_special_tokens: hide <|eot|> etc.
        const tokenizer = activePipeline.tokenizer;
        if (!tokenizer) {
          self.postMessage({
            type: "error",
            id,
            error: "Streaming requires a tokenizer on the pipeline. Current task may not support streaming.",
          });
          return;
        }

        const streamer = new (TextStreamer as any)(tokenizer, {
          skip_prompt: true,
          skip_special_tokens: true,
          callback_function: (text: string) => {
            if (text) self.postMessage({ type: "stream_chunk", id, text });
          },
        });

        await activePipeline(messages, { ...options, streamer });
        self.postMessage({ type: "stream_complete", id });
        break;
      }

      case "embed": {
        if (!activePipeline) {
          self.postMessage({ type: "error", id, error: "Pipeline not initialized" });
          return;
        }
        if (currentTask !== "feature-extraction") {
          self.postMessage({
            type: "error",
            id,
            error: `Embeddings require pipelineTask="feature-extraction". Current task: "${currentTask}".`,
          });
          return;
        }
        const inputs = data.inputs;
        const result = await activePipeline(inputs, {
          pooling: data.pooling || "mean",
          normalize: data.normalize !== false,
        });
        self.postMessage({
          type: "embed_complete",
          id,
          data: tensorToArray(result),
        });
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

function buildTextGenArgs(requestBody: any): { messages: any[]; options: any } {
  const { messages: rawMessages, max_tokens, max_completion_tokens, temperature, top_p } = requestBody;
  const maxNewTokens = max_tokens ?? max_completion_tokens ?? 256;
  const temp = temperature ?? 0.7;
  const topPVal = top_p ?? 1.0;

  const messages = (rawMessages || []).map((m: any) => ({
    ...m,
    content: flattenContent(m.content),
  }));

  const options: any = {
    max_new_tokens: maxNewTokens,
    temperature: temp,
    top_p: topPVal,
    do_sample: temp > 0,
    return_full_text: false,
  };
  return { messages, options };
}
