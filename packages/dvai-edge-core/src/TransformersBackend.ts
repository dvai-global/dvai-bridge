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
 */

export type DeviceType = "webgpu" | "cpu" | "auto";

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
 * is run, while DvAI handles everything else (MSW, OpenAI endpoint, etc.).
 */
export type CreatePipelineFn = (
	transformers: any,
	ctx: {
		modelId: string;
		device: "webgpu" | "wasm";
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
	 * Optional custom pipeline factory. When provided, replaces the default
	 * `pipeline()` call during main-thread initialization.
	 * Use this for models that require direct loading (e.g. Gemma 4, multimodal
	 * models) or any architecture not supported by the pipeline() API.
	 */
	createPipeline?: CreatePipelineFn;
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
	private resolvedDevice: "webgpu" | "wasm" = "wasm";
	private generationTimeout: number;
	private workerUrl?: string;
	private pipelineTask: PipelineTask;
	private dtype?: string;
	private createPipelineFn?: CreatePipelineFn;
	private usingWorker: boolean = false;
	private pendingRequests: Map<
		string,
		{
			resolve: (value: any) => void;
			reject: (error: any) => void;
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
	}

	async initialize(onProgress?: (info: any) => void): Promise<void> {
		// Resolve device
		if (this.device === "auto") {
			const hasWebGPU = await detectWebGPU();
			this.resolvedDevice = hasWebGPU ? "webgpu" : "wasm";
			console.log(
				`[DvAI/Transformers] Auto-detected device: ${this.resolvedDevice}`,
			);
		} else {
			// Map "cpu" to "wasm" for Transformers.js v3/v4 compatibility
			this.resolvedDevice =
				this.device === "cpu" ? "wasm" : (this.device as any);
		}

		// Try worker-based initialization (recommended for CPU mode, good practice for WebGPU too)
		if (this.workerUrl && typeof Worker !== "undefined") {
			try {
				await this.initializeWithWorker(onProgress);
				return;
			} catch (err) {
				console.warn(
					"[DvAI/Transformers] Worker initialization failed, falling back to main thread:",
					err,
				);
				this.worker = null;
			}
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
							"[DvAI/Transformers] Initialized with Web Worker (main thread unblocked)",
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
			};
			console.log("[DvAI/Transformers] Sending init to worker:", initParams);
			worker.postMessage(initParams);
		});
	}

	private handleWorkerMessage(event: MessageEvent) {
		const msg = event.data;
		if (!msg.id) return;

		const pending = this.pendingRequests.get(msg.id);
		if (!pending) return;

		switch (msg.type) {
			case "generate_complete":
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
			console.log("[DvAI/Transformers] Using custom createPipeline factory.");
			this.pipeline = await this.createPipelineFn(transformers, {
				modelId: this.modelId,
				device: this.resolvedDevice,
				dtype: this.dtype,
				onProgress: progressCallback,
			});
		} else {
			this.pipeline = await pipelineFn(this.pipelineTask as any, this.modelId, {
				device: this.resolvedDevice,
				progress_callback: progressCallback,
				dtype: this.dtype as any,
			});
		}
		this.usingWorker = false;

		if (this.resolvedDevice === "wasm") {
			console.warn(
				"[DvAI/Transformers] Running on main thread with WASM (CPU) — inference may block the UI. " +
					"Set `workerUrl` to a deployed transformers worker for better performance.",
			);
		} else {
			console.log(
				"[DvAI/Transformers] Initialized on main thread (WebGPU compute is async)",
			);
		}
	}

	getPipelineTask(): PipelineTask {
		return this.pipelineTask;
	}

	getResolvedDevice(): "webgpu" | "wasm" {
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
			console.log("[DvAI/Transformers] Running local inference:", messages);
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
	 * OpenAI-compatible streaming chat completion.
	 * Returns a ReadableStream of SSE-formatted data.
	 */
	createStreamingResponse(requestBody: any): ReadableStream<Uint8Array> {
		const modelId = this.modelId;
		const backend = this;

		return new ReadableStream<Uint8Array>({
			async start(controller) {
				const completionId = `chatcmpl-${Date.now()}`;
				const created = Math.floor(Date.now() / 1000);

				try {
					// Generate full response (worker or main thread), then simulate streaming
					const response = await backend.chatCompletion(requestBody);
					const content: string = response.choices[0]?.message?.content ?? "";

					// Emit content word-by-word for a streaming experience
					const words = content.split(/(?<=\s)/);

					for (const word of words) {
						const chunk = {
							id: completionId,
							object: "chat.completion.chunk",
							created,
							model: modelId,
							choices: [
								{
									index: 0,
									delta: { content: word },
									finish_reason: null,
								},
							],
						};
						controller.enqueue(
							new TextEncoder().encode(`data: ${JSON.stringify(chunk)}\n\n`),
						);
					}

					// Final chunk with finish_reason
					const finalChunk = {
						id: completionId,
						object: "chat.completion.chunk",
						created,
						model: modelId,
						choices: [
							{
								index: 0,
								delta: {},
								finish_reason: "stop",
							},
						],
					};
					controller.enqueue(
						new TextEncoder().encode(`data: ${JSON.stringify(finalChunk)}\n\n`),
					);
				} catch (error: any) {
					console.error("[DvAI/Transformers] Stream error:", error.message);
					controller.enqueue(
						new TextEncoder().encode(
							`data: ${JSON.stringify({ error: error.message })}\n\n`,
						),
					);
				} finally {
					controller.enqueue(new TextEncoder().encode("data: [DONE]\n\n"));
					controller.close();
				}
			},
		});
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
