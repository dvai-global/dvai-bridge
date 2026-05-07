/**
 * TransformersBackend: Wraps @huggingface/transformers for local inference.
 * - Multi-modal: supports any Transformers.js pipeline task (text-generation,
 *   text-to-image, automatic-speech-recognition, image-to-text, etc.)
 * - Runs inference in a Web Worker to keep the main thread unblocked
 * - Falls back to main-thread pipeline if worker URL is not available
 * - Auto-detects WebGPU, falls back to CPU
 * - Provides OpenAI-compatible chat completion API for text-generation tasks
 * - Supports streaming responses for text tasks
 * - Direct pipeline access via runPipeline() for all modalities
 * - Timeout protection on all operations
 * - Three loader paths, in priority order:
 *     1. Main-thread `createPipeline` factory (when provided) — gives the
 *        host complete control; used for models that need a custom
 *        processor call signature that the declarative path doesn't cover.
 *     2. Declarative `modelClass` + `processorClass` + `disableEncoders`
 *        — works in the worker AND on the main thread. Use this for any
 *        multimodal model that follows the common processor signature.
 *     3. Generic `pipeline(task, modelId)` — the default, good for 99% of
 *        transformers.js tasks.
 */

import {
	buildMultimodalCallable,
	disableModelEncoders,
} from "./multimodalCallable.js";

export type DeviceType = "webgpu" | "cpu" | "auto";

/**
 * Convert a Transformers.js Tensor (or plain array) into a nested number[][].
 * Handles both single-input and batched feature-extraction outputs.
 */
function tensorToArray(t: any): number[][] {
	if (!t) return [];
	if (Array.isArray(t)) {
		if (t.length > 0 && Array.isArray(t[0])) return t as number[][];
		return [t as number[]];
	}
	if (typeof t.tolist === "function") {
		const arr = t.tolist();
		if (Array.isArray(arr) && arr.length > 0 && Array.isArray(arr[0]))
			return arr;
		return [arr];
	}
	if (t.data && t.dims) {
		const [batch, hidden] =
			t.dims.length === 2 ? t.dims : [1, t.dims[t.dims.length - 1]];
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

/**
 * Supported pipeline tasks from Transformers.js.
 * Common tasks include:
 * - "text-generation" (default) — LLM chat/text generation
 * - "text2text-generation" — encoder-decoder text models
 * - "text-to-image" — image generation from text prompts
 * - "image-to-text" — image captioning
 * - "automatic-speech-recognition" — audio/speech to text
 * - "text-to-speech" — text to audio
 * - "zero-shot-classification" — classify without training
 * - "feature-extraction" — embeddings
 * - "translation" — language translation
 * - "summarization" — text summarization
 * - And many more: see https://huggingface.co/docs/transformers.js
 */
export type PipelineTask = string;

/**
 * A pipeline-compatible callable function.
 * Accepts messages (chat format) and generation options,
 * returns results in the same shape as a Transformers.js pipeline:
 *   [{ generated_text: string }]
 */
export type PipelineCallable = (messages: any, options?: any) => Promise<any>;

/**
 * Factory function that the client can supply to customize model loading.
 * Receives the dynamically-imported @huggingface/transformers module and
 * config details; must return a PipelineCallable.
 *
 * This lets the client control *how* the model is loaded and how inference
 * is run, while DVAI handles everything else (MSW, OpenAI endpoint, etc.).
 */
export type CreatePipelineFn = (
	transformers: any,
	ctx: {
		modelId: string;
		device: "webgpu" | "wasm" | "cpu";
		dtype?: string;
		onProgress?: (info: any) => void;
	},
) => Promise<PipelineCallable>;

export interface TransformersBackendConfig {
	modelId: string;
	device: DeviceType;
	generationTimeout: number;
	workerUrl?: string;
	/** The pipeline task to use. Default: "text-generation" */
	pipelineTask?: PipelineTask;
	/** Quantization/DType for the model (e.g. 'q4', 'q8', 'f16'). Default: undefined */
	dtype?: string;
	/**
	 * Optional custom pipeline factory. Main-thread only (function closures
	 * don't cross the Worker boundary — use `modelClass`/`processorClass`
	 * for the worker path instead). Replaces the default `pipeline()` call.
	 * Use this when your model's processor takes a non-standard call
	 * signature that the declarative multimodal callable can't express.
	 */
	createPipeline?: CreatePipelineFn;
	/**
	 * Name of a transformers.js export to use as the model class, loaded via
	 * `ClassName.from_pretrained(modelId)`. Enables the declarative
	 * multimodal loader path (works in the worker and on main thread).
	 * Examples: "Gemma4ForConditionalGeneration", "LlavaForConditionalGeneration",
	 * "AutoModelForCausalLM". When unset, falls back to `pipeline()`.
	 */
	modelClass?: string;
	/**
	 * Name of a transformers.js export to use as the processor class.
	 * Only used when `modelClass` is set. Default: "AutoProcessor".
	 */
	processorClass?: string;
	/**
	 * Model submodule fields to null out after `from_pretrained`, e.g.
	 * `["vision_encoder"]` for a voice-only host app using a multimodal
	 * checkpoint. Purely declarative — backend walks the list and nulls
	 * each named field if present. Unknown/absent names are ignored.
	 */
	disableEncoders?: string[];
}

export interface TransformersProgressInfo {
	status: string;
	name?: string;
	file?: string;
	progress?: number;
	loaded?: number;
	total?: number;
}

/**
 * Detects whether WebGPU is available in the current environment.
 */
export async function detectWebGPU(): Promise<boolean> {
	if (typeof navigator === "undefined") return false;
	if (!("gpu" in navigator)) return false;
	try {
		const adapter = await (navigator as any).gpu.requestAdapter();
		return adapter !== null;
	} catch {
		return false;
	}
}

export class TransformersBackend {
	private pipeline: any = null;
	private worker: Worker | null = null;
	private modelId: string;
	private device: DeviceType;
	private resolvedDevice: "webgpu" | "wasm" | "cpu" = "wasm";
	private generationTimeout: number;
	private workerUrl?: string;
	private pipelineTask: PipelineTask;
	private dtype?: string;
	private createPipelineFn?: CreatePipelineFn;
	private modelClass?: string;
	private processorClass?: string;
	private disableEncoders?: string[];
	private usingWorker: boolean = false;
	private pendingRequests: Map<
		string,
		{
			resolve: (value: any) => void;
			reject: (error: any) => void;
		}
	> = new Map();
	private pendingStreams: Map<
		string,
		{
			onChunk: (text: string) => void;
			onComplete: () => void;
			onError: (error: any) => void;
		}
	> = new Map();

	constructor(config: TransformersBackendConfig) {
		this.modelId = config.modelId;
		this.device = config.device;
		this.generationTimeout = config.generationTimeout;
		this.workerUrl = config.workerUrl;
		this.pipelineTask = config.pipelineTask || "text-generation";
		this.dtype = config.dtype;
		this.createPipelineFn = config.createPipeline;
		this.modelClass = config.modelClass;
		this.processorClass = config.processorClass;
		this.disableEncoders = config.disableEncoders;
	}

	async initialize(onProgress?: (info: any) => void): Promise<void> {
		// Resolve device.
		//
		// Runtime split:
		//   - Browser → onnxruntime-web → accepts "wasm" + "webgpu". CPU is "wasm".
		//   - Node    → onnxruntime-node → accepts "cpu" + "dml" + "webgpu" (experimental).
		//                                  Throws on "wasm".
		//
		// Detect once and route accordingly. Without this branch, Node hosts
		// (the v3.1 Hub, the node-langchain example, etc.) fail to initialize
		// with "Unsupported device: \"wasm\"".
		const isNode =
			typeof window === "undefined" &&
			typeof process !== "undefined" &&
			(process as any).versions?.node !== undefined;

		if (this.device === "auto") {
			const hasWebGPU = await detectWebGPU();
			this.resolvedDevice = hasWebGPU ? "webgpu" : isNode ? "cpu" : "wasm";
			console.log(
				`[DVAI/Transformers] Auto-detected device: ${this.resolvedDevice}`,
			);
		} else if (this.device === "cpu") {
			this.resolvedDevice = isNode ? "cpu" : "wasm";
		} else {
			this.resolvedDevice = this.device as "webgpu" | "wasm" | "cpu";
		}

		// Worker-based initialization is the DEFAULT path. Running inference
		// off the main thread is a baseline guarantee dvai-bridge makes to
		// every host app — no host should have to worry about Gemma / Llama /
		// whisper forward-passes stalling their UI. The Worker constructor
		// auto-falls back to main-thread only in truly broken environments
		// (Worker unavailable, or the bundled worker file failed to load).
		if (this.workerUrl && typeof Worker !== "undefined") {
			try {
				await this.initializeWithWorker(onProgress);
				return;
			} catch (err) {
				// Raised to error level + remediation tip. Silent main-thread
				// fallback was hiding deployment bugs where the worker file
				// wasn't copied to public/.
				console.error(
					"[DVAI/Transformers] Worker initialization FAILED — falling back to main thread. " +
						"This WILL block the UI during inference. Check that the worker file is " +
						`deployed at "${this.workerUrl}" (run \`dvai-bridge init\` to copy it).`,
					err,
				);
				this.worker = null;
			}
		} else if (!this.workerUrl) {
			console.warn(
				"[DVAI/Transformers] No workerUrl configured — running on main thread. " +
					"This blocks the UI during inference. Set `transformersWorkerUrl` " +
					"(defaults to '/dvai-transformers.worker.js') to enable the worker path.",
			);
		}

		// Fallback: main-thread pipeline
		await this.initializeMainThread(onProgress);
	}

	private async initializeWithWorker(
		onProgress?: (info: any) => void,
	): Promise<void> {
		return new Promise<void>((resolve, reject) => {
			const worker = new Worker(this.workerUrl!, { type: "module" });
			const requestId = this.generateRequestId();

			const handleMessage = (event: MessageEvent) => {
				const msg = event.data;
				if (msg.id !== requestId) return;

				switch (msg.type) {
					case "progress":
						if (onProgress) {
							const info = msg.data;
							const progressValue = info.progress ?? 0;
							const text =
								info.status === "progress"
									? `Downloading ${info.file}: ${Math.round(progressValue)}%`
									: info.status === "ready"
										? "Model ready"
										: `${info.status}${info.file ? `: ${info.file}` : ""}`;
							onProgress({
								text,
								progress: progressValue / 100,
								timeElapsed: 0,
							});
						}
						break;
					case "init_complete":
						worker.removeEventListener("message", handleMessage);
						this.worker = worker;
						this.usingWorker = true;

						// Set up persistent message handler for future requests
						worker.addEventListener("message", (e: MessageEvent) =>
							this.handleWorkerMessage(e),
						);

						console.log(
							"[DVAI/Transformers] Initialized with Web Worker (main thread unblocked)",
						);
						resolve();
						break;
					case "error":
						worker.removeEventListener("message", handleMessage);
						worker.terminate();
						reject(new Error(msg.error));
						break;
				}
			};

			worker.addEventListener("message", handleMessage);
			worker.addEventListener("error", (err: any) => {
				worker.removeEventListener("message", handleMessage);
				const errorMessage =
					err.message ||
					(err.error ? err.error.message : "Unknown worker error");
				reject(new Error(`Worker error: ${errorMessage}`));
			});

			const initParams = {
				type: "init",
				id: requestId,
				pipelineTask: this.pipelineTask,
				modelId: this.modelId,
				device: this.resolvedDevice,
				dtype: this.dtype,
				// Declarative loader config — worker uses these to pick the
				// model+processor path when modelClass is set, otherwise it
				// falls back to pipeline(task, modelId). Host app controls
				// which class to load, which processor to pair with it, and
				// which encoder submodules to null after load.
				modelClass: this.modelClass,
				processorClass: this.processorClass,
				disableEncoders: this.disableEncoders,
			};
			console.log("[DVAI/Transformers] Sending init to worker:", initParams);
			worker.postMessage(initParams);
		});
	}

	private handleWorkerMessage(event: MessageEvent) {
		const msg = event.data;
		if (!msg.id) return;

		// Streaming messages first — they share an id with pendingStreams
		const stream = this.pendingStreams.get(msg.id);
		if (stream) {
			switch (msg.type) {
				case "stream_chunk":
					stream.onChunk(msg.text);
					return;
				case "stream_complete":
					this.pendingStreams.delete(msg.id);
					stream.onComplete();
					return;
				case "error":
					this.pendingStreams.delete(msg.id);
					stream.onError(
						new Error(msg.error || "Unknown worker internal error"),
					);
					return;
			}
		}

		const pending = this.pendingRequests.get(msg.id);
		if (!pending) return;

		switch (msg.type) {
			case "generate_complete":
			case "embed_complete":
				this.pendingRequests.delete(msg.id);
				pending.resolve(msg.data);
				break;
			case "unload_complete":
				this.pendingRequests.delete(msg.id);
				pending.resolve(undefined);
				break;
			case "error":
				this.pendingRequests.delete(msg.id);
				pending.reject(new Error(msg.error || "Unknown worker internal error"));
				break;
		}
	}

	private sendWorkerRequest(
		type: string,
		data: Record<string, any> = {},
	): Promise<any> {
		return new Promise((resolve, reject) => {
			const id = this.generateRequestId();
			this.pendingRequests.set(id, { resolve, reject });
			this.worker!.postMessage({ type, id, ...data });
		});
	}

	private async initializeMainThread(
		onProgress?: (info: any) => void,
	): Promise<void> {
		// @ts-ignore - module resolved at runtime after pnpm install
		const transformers = await import("@huggingface/transformers");
		const { pipeline: pipelineFn, env } = transformers;

		// Only allow local models if explicitly requested or if we're in a specific environment.
		// Defaulting to false ensures CDN fallback when local models are not provided.
		// Force remote models from Hugging Face CDN
		env.allowLocalModels = false;
		env.allowRemoteModels = true;
		env.remoteHost = "https://huggingface.co";
		env.remotePathTemplate = "{model}/resolve/{revision}/";

		const progressCallback = onProgress
			? (info: TransformersProgressInfo) => {
					const progressValue = info.progress ?? 0;
					const text =
						info.status === "progress"
							? `Downloading ${info.file}: ${Math.round(progressValue)}%`
							: info.status === "ready"
								? `Model ready (${this.pipelineTask})`
								: `${info.status}${info.file ? `: ${info.file}` : ""}`;
					onProgress({ text, progress: progressValue / 100, timeElapsed: 0 });
				}
			: undefined;

		if (this.createPipelineFn) {
			// Client-supplied custom pipeline factory — use it instead of pipeline().
			console.log("[DVAI/Transformers] Using custom createPipeline factory.");
			this.pipeline = await this.createPipelineFn(transformers, {
				modelId: this.modelId,
				device: this.resolvedDevice,
				dtype: this.dtype,
				onProgress: progressCallback,
			});
		} else if (this.modelClass) {
			// Declarative model+processor loader — same contract as the
			// worker path. Keeps behavior consistent regardless of which
			// path the env ends up on (e.g., a dev running without the
			// worker file deployed yet).
			console.log(
				`[DVAI/Transformers] Using declarative loader: ${this.modelClass} + ${this.processorClass || "AutoProcessor"}`,
			);
			const ModelClass = (transformers as any)[this.modelClass];
			if (!ModelClass) {
				throw new Error(
					`transformers.js has no export named "${this.modelClass}". Check your modelClass config.`,
				);
			}
			const processorName = this.processorClass || "AutoProcessor";
			const ProcessorClass = (transformers as any)[processorName];
			if (!ProcessorClass) {
				throw new Error(
					`transformers.js has no export named "${processorName}". Check your processorClass config.`,
				);
			}
			const processor = await ProcessorClass.from_pretrained(this.modelId, {
				progress_callback: progressCallback,
			});
			const model = await ModelClass.from_pretrained(this.modelId, {
				dtype: this.dtype as any,
				device: this.resolvedDevice,
				progress_callback: progressCallback,
			});
			disableModelEncoders(model, this.disableEncoders);
			this.pipeline = buildMultimodalCallable(model, processor);
		} else {
			this.pipeline = await pipelineFn(this.pipelineTask as any, this.modelId, {
				device: this.resolvedDevice,
				progress_callback: progressCallback,
				dtype: this.dtype as any,
			});
		}
		this.usingWorker = false;

		if (this.resolvedDevice === "wasm" || this.resolvedDevice === "cpu") {
			console.warn(
				`[DVAI/Transformers] Running on main thread with ${this.resolvedDevice.toUpperCase()} (CPU). ` +
					(this.resolvedDevice === "wasm"
						? "Inference may block the UI. Set `workerUrl` to a deployed transformers worker for better performance."
						: "(Node host — no UI thread to block.)"),
			);
		} else {
			console.log(
				"[DVAI/Transformers] Initialized on main thread (WebGPU compute is async)",
			);
		}
	}

	getPipelineTask(): PipelineTask {
		return this.pipelineTask;
	}

	getResolvedDevice(): "webgpu" | "wasm" | "cpu" {
		return this.resolvedDevice;
	}

	isWorkerBased(): boolean {
		return this.usingWorker;
	}

	getPipeline(): any {
		return this.pipeline;
	}

	/**
	 * Returns whether the current task is a text generation task
	 * (supports OpenAI-compatible chat completion API).
	 */
	isTextTask(): boolean {
		return [
			"text-generation",
			"text2text-generation",
			"summarization",
			"translation",
			"image-text-to-text",
			"any-to-any",
		].includes(this.pipelineTask);
	}

	/**
	 * Run the pipeline directly with arbitrary inputs.
	 * Use this for non-text-generation tasks (text-to-image, STT, etc.)
	 * or when you need full control over the pipeline output.
	 *
	 * @param inputs - Input data (text, audio buffer, image URL, etc.)
	 * @param options - Pipeline-specific options
	 * @returns Raw pipeline output (varies by task)
	 */
	async runPipeline(inputs: any, options?: Record<string, any>): Promise<any> {
		if (this.usingWorker && this.worker) {
			return this.withTimeout(
				this.sendWorkerRequest("generate", {
					requestBody: { raw: true, inputs, options },
				}),
				this.generationTimeout,
			);
		}
		if (!this.pipeline)
			throw new Error("Transformers.js pipeline not initialized");
		return this.withTimeout(
			this.pipeline(inputs, options),
			this.generationTimeout,
		);
	}

	/**
	 * OpenAI-compatible non-streaming chat completion.
	 * Only works for text-generation / text2text-generation tasks.
	 */
	async chatCompletion(requestBody: any): Promise<any> {
		if (!this.isTextTask()) {
			throw new Error(
				`chatCompletion() is only available for text-generation tasks. ` +
					`Current task: "${this.pipelineTask}". Use runPipeline() instead.`,
			);
		}

		// Aggressive sanitization: ensure content is ALWAYS a string
		const messages = (requestBody.messages || []).map((m: any) => ({
			...m,
			content: flattenContent(m.content),
		}));

		const maxNewTokens =
			requestBody.max_tokens ?? requestBody.max_completion_tokens ?? 256;
		const temperature = requestBody.temperature ?? 0.7;
		const topP = requestBody.top_p ?? 1.0;

		const options: any = {
			max_new_tokens: maxNewTokens,
			temperature,
			top_p: topP,
			do_sample: temperature > 0,
			return_full_text: false,
		};

		let result: any;
		if (this.usingWorker && this.worker) {
			// Run inference in worker
			result = await this.withTimeout(
				this.sendWorkerRequest("generate", {
					requestBody: { ...requestBody, messages },
				}),
				this.generationTimeout,
			);
		} else if (this.pipeline) {
			// Run inference on main thread
			console.log("[DVAI/Transformers] Running local inference:", messages);
			result = await this.withTimeout(
				this.pipeline(messages, options),
				this.generationTimeout,
			);
		} else {
			throw new Error("Transformers.js backend not initialized");
		}

		// Extract generated text
		const generatedText = (result as any)?.[0]?.generated_text ?? "";
		const content =
			typeof generatedText === "string"
				? generatedText
				: Array.isArray(generatedText)
					? (generatedText[generatedText.length - 1]?.content ?? "")
					: String(generatedText);

		return {
			id: `chatcmpl-${Date.now()}`,
			object: "chat.completion",
			created: Math.floor(Date.now() / 1000),
			model: this.modelId,
			choices: [
				{
					index: 0,
					message: { role: "assistant", content },
					finish_reason: "stop",
				},
			],
			usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
		};
	}

	/**
	 * OpenAI-compatible streaming chat completion using real token-level streaming
	 * via Transformers.js TextStreamer. Returns a ReadableStream of SSE-formatted data.
	 */
	createStreamingResponse(requestBody: any): ReadableStream<Uint8Array> {
		if (!this.isTextTask()) {
			throw new Error(
				`Streaming chat completion is only available for text-generation tasks. ` +
					`Current task: "${this.pipelineTask}".`,
			);
		}

		const modelId = this.modelId;
		const backend = this;
		const generationTimeout = this.generationTimeout;

		return new ReadableStream<Uint8Array>({
			async start(controller) {
				const completionId = `chatcmpl-${Date.now()}`;
				const created = Math.floor(Date.now() / 1000);
				const encoder = new TextEncoder();

				const enqueueChunk = (text: string) => {
					const chunk = {
						id: completionId,
						object: "chat.completion.chunk",
						created,
						model: modelId,
						choices: [
							{ index: 0, delta: { content: text }, finish_reason: null },
						],
					};
					controller.enqueue(
						encoder.encode(`data: ${JSON.stringify(chunk)}\n\n`),
					);
				};

				const enqueueFinal = (finishReason: string = "stop") => {
					const finalChunk = {
						id: completionId,
						object: "chat.completion.chunk",
						created,
						model: modelId,
						choices: [{ index: 0, delta: {}, finish_reason: finishReason }],
					};
					controller.enqueue(
						encoder.encode(`data: ${JSON.stringify(finalChunk)}\n\n`),
					);
				};

				let timeoutId: ReturnType<typeof setTimeout> | null = null;
				try {
					const streamPromise = new Promise<void>((resolve, reject) => {
						if (backend.usingWorker && backend.worker) {
							const id = backend.generateRequestId();
							backend.pendingStreams.set(id, {
								onChunk: enqueueChunk,
								onComplete: resolve,
								onError: reject,
							});
							backend.worker.postMessage({
								type: "generate_stream",
								id,
								requestBody,
							});
						} else if (backend.pipeline) {
							// Main-thread streaming via TextStreamer.
							// Lazy-load @huggingface/transformers to access TextStreamer without
							// importing it at top-level (keeps the main bundle lean).
							// eslint-disable-next-line @typescript-eslint/no-floating-promises
							(async () => {
								try {
									// @ts-ignore - module resolved at runtime
									const { TextStreamer } =
										await import("@huggingface/transformers");
									const tokenizer = (backend.pipeline as any).tokenizer;
									if (!tokenizer) {
										throw new Error(
											"Streaming requires a tokenizer on the pipeline.",
										);
									}

									const messages = (requestBody.messages || []).map(
										(m: any) => ({
											...m,
											content: flattenContent(m.content),
										}),
									);
									const options: any = {
										max_new_tokens:
											requestBody.max_tokens ??
											requestBody.max_completion_tokens ??
											256,
										temperature: requestBody.temperature ?? 0.7,
										top_p: requestBody.top_p ?? 1.0,
										do_sample: (requestBody.temperature ?? 0.7) > 0,
										return_full_text: false,
										streamer: new TextStreamer(tokenizer, {
											skip_prompt: true,
											skip_special_tokens: true,
											callback_function: (text: string) => {
												if (text) enqueueChunk(text);
											},
										}),
									};

									await backend.pipeline(messages, options);
									resolve();
								} catch (e) {
									reject(e);
								}
							})();
						} else {
							reject(new Error("Transformers.js backend not initialized"));
						}
					});

					const timeoutPromise = new Promise<never>((_, reject) => {
						timeoutId = setTimeout(
							() =>
								reject(
									new Error(
										`Generation timed out after ${generationTimeout}ms`,
									),
								),
							generationTimeout,
						);
					});

					await Promise.race([streamPromise, timeoutPromise]);
					enqueueFinal("stop");
				} catch (error: any) {
					console.error("[DVAI/Transformers] Stream error:", error.message);
					controller.enqueue(
						encoder.encode(
							`data: ${JSON.stringify({ error: error.message })}\n\n`,
						),
					);
				} finally {
					if (timeoutId) clearTimeout(timeoutId);
					controller.enqueue(encoder.encode("data: [DONE]\n\n"));
					controller.close();
				}
			},
		});
	}

	/**
	 * Generate embeddings for one or more text inputs.
	 * Requires the pipeline to have been initialized with pipelineTask="feature-extraction".
	 *
	 * @param inputs - A single string or array of strings to embed
	 * @returns An array of embedding vectors (one per input)
	 */
	async embedding(inputs: string | string[]): Promise<number[][]> {
		if (this.pipelineTask !== "feature-extraction") {
			throw new Error(
				`embedding() requires pipelineTask="feature-extraction". Current task: "${this.pipelineTask}".`,
			);
		}

		const inputArray = Array.isArray(inputs) ? inputs : [inputs];

		if (this.usingWorker && this.worker) {
			const result = await this.withTimeout(
				this.sendWorkerRequest("embed", {
					inputs: inputArray,
					pooling: "mean",
					normalize: true,
				}),
				this.generationTimeout,
			);
			return result as number[][];
		}

		if (!this.pipeline) {
			throw new Error("Transformers.js pipeline not initialized");
		}

		const raw = await this.withTimeout(
			this.pipeline(inputArray, { pooling: "mean", normalize: true }),
			this.generationTimeout,
		);
		return tensorToArray(raw);
	}

	async unload(): Promise<void> {
		if (this.usingWorker && this.worker) {
			try {
				await this.sendWorkerRequest("unload");
			} catch (_) {
				/* best effort */
			}
			this.worker.terminate();
			this.worker = null;
		}

		if (this.pipeline) {
			if (typeof this.pipeline.dispose === "function") {
				await this.pipeline.dispose();
			}
			this.pipeline = null;
		}

		this.pendingRequests.clear();
		this.usingWorker = false;
	}

	/** Wraps a promise with a timeout. */
	private withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
		return new Promise<T>((resolve, reject) => {
			const timer = setTimeout(
				() => reject(new Error(`Generation timed out after ${ms}ms`)),
				ms,
			);
			promise
				.then((val) => {
					clearTimeout(timer);
					resolve(val);
				})
				.catch((err) => {
					clearTimeout(timer);
					reject(err);
				});
		});
	}

	private generateRequestId(): string {
		return `${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
	}
}
