/**
 * Transformers.js Web Worker Entry Point
 * Runs inference inside a Web Worker to keep the main thread unblocked.
 * Supports any pipeline task (text-generation, text-to-image, ASR,
 * feature-extraction, etc.).
 *
 * Special case: Gemma-4 multimodal models (detected by modelId pattern
 * `gemma-4-...`) bypass the generic `pipeline()` init and load
 * `Gemma4ForConditionalGeneration` + `AutoProcessor` directly so we can
 * feed audio `Float32Array` through the processor's third positional
 * argument. The vision_encoder is nulled after load to reclaim ~99 MB
 * since the worker-invocation flow currently routes via `runPipeline`
 * (which accepts text + audio content parts). Audio bytes travel from
 * main thread → worker via `postMessage` structured clone, NOT JSON, so
 * `Float32Array` survives the hop intact.
 *
 * This special-casing keeps the library's promise: "load Gemma-4 in a
 * worker and it just works" without each host app having to ship a
 * custom worker file. Other custom-pipeline cases continue to use the
 * main-thread `createPipeline` factory path.
 *
 * Deploy this file to your public directory via `dvai-bridge init`.
 */
// @ts-ignore - module resolved at runtime
import {
  pipeline,
  env,
  TextStreamer,
  // @ts-ignore - exported at runtime; not always in the package's type defs
  AutoProcessor,
  // @ts-ignore - exported at runtime; not always in the package's type defs
  Gemma4ForConditionalGeneration,
} from "@huggingface/transformers";

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
 * Detects Gemma-4 multimodal models (e.g. "onnx-community/gemma-4-E2B-it-ONNX",
 * "onnx-community/gemma-4-E4B-it-ONNX"). These need a custom init path to
 * load `Gemma4ForConditionalGeneration` + `AutoProcessor` so audio input
 * can reach the processor's audio arg.
 */
function isGemma4Multimodal(modelId: string): boolean {
  return /\bgemma-4-/i.test(modelId);
}

/**
 * Extract the first audio `Float32Array` from a message's content array,
 * using the dvai-bridge convention `{ type: "audio", data: Float32Array }`.
 * Returns null if no audio part exists.
 */
function extractAudio(messages: any[]): Float32Array | null {
  const last = messages[messages.length - 1];
  if (!last || !Array.isArray(last.content)) return null;
  for (const part of last.content) {
    if (part && part.type === "audio" && part.data) {
      return part.data as Float32Array;
    }
  }
  return null;
}

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
 * - { type: "init", pipelineTask, modelId, device } → initialize pipeline
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

        if (isGemma4Multimodal(data.modelId)) {
          // Gemma-4 multimodal custom init: load ForConditionalGeneration +
          // AutoProcessor directly so we can feed audio. Vision_encoder is
          // nulled after load to reclaim ~99 MB since the runPipeline flow
          // only uses text + audio content parts today.
          const processor = await (AutoProcessor as any).from_pretrained(
            data.modelId,
            {
              progress_callback: (info: any) => {
                self.postMessage({ type: "progress", id, data: info });
              },
            },
          );
          const model = await (Gemma4ForConditionalGeneration as any).from_pretrained(
            data.modelId,
            {
              dtype: data.dtype,
              device: device,
              progress_callback: (info: any) => {
                self.postMessage({ type: "progress", id, data: info });
              },
            },
          );
          try {
            if (model.vision_encoder) model.vision_encoder = null;
          } catch {
            /* ignore */
          }

          // Wrap model+processor as a pipeline-shaped callable: takes
          // (messages, options) → [{ generated_text: string }]. Same contract
          // as the main-thread custom callable so the same message shapes
          // work against either path (main-thread `createPipeline` or this
          // worker path).
          const callable: any = async (messages: any, options: any) => {
            const prompt = processor.apply_chat_template(messages, {
              enable_thinking: false,
              add_generation_prompt: true,
            });
            const audio = extractAudio(messages);
            const inputs = await processor(prompt, null, audio, {
              add_special_tokens: false,
            });
            const genArgs: Record<string, unknown> = {
              ...inputs,
              max_new_tokens: options?.max_new_tokens ?? 1024,
              temperature: options?.temperature ?? 0,
              do_sample: options?.do_sample ?? false,
              top_p: options?.top_p ?? 1,
            };
            if (options?.streamer) genArgs.streamer = options.streamer;
            const outputs = await model.generate(genArgs);
            const promptLen = inputs.input_ids.dims.at(-1);
            const generated = outputs.slice(null, [promptLen, null]);
            const decoded = processor.batch_decode(generated, {
              skip_special_tokens: true,
            });
            return [{ generated_text: decoded[0] ?? "" }];
          };

          // Expose tokenizer for `generate_stream` (TextStreamer needs it).
          callable.tokenizer = processor.tokenizer;
          // Dispose hook so the "unload" handler frees VRAM.
          callable.dispose = async () => {
            try {
              await model.dispose?.();
            } catch {
              /* ignore */
            }
          };

          activePipeline = callable;
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
