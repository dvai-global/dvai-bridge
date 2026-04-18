/**
 * NativeBackend: Wraps llama-cpp-capacitor for native on-device inference.
 * - Uses llama.cpp via Capacitor plugin for Metal (iOS) / Vulkan (Android)
 * - Provides OpenAI-compatible chat completion response format
 * - Supports streaming via token callbacks
 * - Falls back gracefully when not running in Capacitor
 */

export interface NativeBackendConfig {
	modelPath: string;
	contextSize?: number;
	threads?: number;
	gpuLayers?: number;
	generationTimeout?: number;
	/**
	 * Initialize the llama.cpp context in embedding mode so `embedding()` can
	 * be used. When true, the context is specialized for producing embeddings
	 * and should typically not be used for chat/completion. Default: false.
	 */
	embeddingMode?: boolean;
}

export class NativeBackend {
	private context: any = null;
	private modelPath: string;
	private contextSize: number;
	private threads: number;
	private gpuLayers: number;
	private generationTimeout: number;
	private embeddingMode: boolean;

	constructor(config: NativeBackendConfig) {
		this.modelPath = config.modelPath;
		this.contextSize = config.contextSize ?? 2048;
		this.threads = config.threads ?? 4;
		this.gpuLayers = config.gpuLayers ?? 99; // Use all available GPU layers
		this.generationTimeout = config.generationTimeout ?? 60000;
		this.embeddingMode = config.embeddingMode ?? false;
	}

	/**
	 * Detect whether we're in a Capacitor Native environment.
	 */
	static isAvailable(): boolean {
		return (
			typeof window !== "undefined" &&
			!!(window as any).Capacitor?.isNativePlatform?.()
		);
	}

	async initialize(onProgress?: (info: any) => void): Promise<void> {
		if (!NativeBackend.isAvailable()) {
			throw new Error(
				"[DVAI/Native] Not running in a Capacitor native environment. " +
					'The "native" backend requires a Capacitor iOS or Android app.',
			);
		}

		let initLlama: any;
		try {
			const mod = await import("llama-cpp-capacitor");
			initLlama = mod.initLlama;
		} catch {
			throw new Error(
				'[DVAI/Native] "llama-cpp-capacitor" is not installed.\n' +
					"Install it with: npm install llama-cpp-capacitor",
			);
		}

		onProgress?.({
			text: "Loading native model...",
			progress: 0,
			timeElapsed: 0,
		});

		const startTime = Date.now();

		this.context = await initLlama(
			{
				model: this.modelPath,
				n_ctx: this.contextSize,
				n_threads: this.threads,
				n_gpu_layers: this.gpuLayers,
				use_mmap: true,
				embedding: this.embeddingMode,
			},
			(progressPercent: number) => {
				onProgress?.({
					text: `Loading model: ${Math.round(progressPercent)}%`,
					progress: progressPercent / 100,
					timeElapsed: Date.now() - startTime,
				});
			},
		);

		onProgress?.({
			text: "Native model loaded",
			progress: 1,
			timeElapsed: Date.now() - startTime,
		});

		console.log(
			`[DVAI/Native] llama.cpp backend ready (ctx: ${this.contextSize}, threads: ${this.threads}, gpu_layers: ${this.gpuLayers})`,
		);
	}

	/**
	 * Non-streaming chat completion.
	 * Accepts OpenAI-format request body {messages, max_tokens, temperature, ...}
	 * Returns OpenAI-format response.
	 */
	async chatCompletion(requestBody: any): Promise<any> {
		if (!this.context) throw new Error("[DVAI/Native] Context not initialized");

		const result: any = await this.withTimeout(
			this.context.completion({
				messages: requestBody.messages,
				n_predict: requestBody.max_tokens ?? 512,
				temperature: requestBody.temperature ?? 0.7,
				top_p: requestBody.top_p ?? 0.9,
				stop: requestBody.stop,
			}),
			this.generationTimeout,
		);

		// Format as OpenAI-compatible response
		return {
			id: `native-${Date.now()}`,
			object: "chat.completion",
			created: Math.floor(Date.now() / 1000),
			model: this.modelPath,
			choices: [
				{
					index: 0,
					message: {
						role: "assistant",
						content: result.content || result.text || "",
					},
					finish_reason: result.stopped_eos
						? "stop"
						: result.stopped_limit
							? "length"
							: "stop",
				},
			],
			usage: {
				prompt_tokens: result.tokens_evaluated ?? 0,
				completion_tokens: result.tokens_predicted ?? 0,
				total_tokens:
					(result.tokens_evaluated ?? 0) + (result.tokens_predicted ?? 0),
			},
		};
	}

	/**
	 * Streaming chat completion.
	 * Returns a ReadableStream of SSE-formatted data (OpenAI streaming format).
	 */
	createStreamingResponse(requestBody: any): ReadableStream<Uint8Array> {
		const context = this.context;
		if (!context) throw new Error("[DVAI/Native] Context not initialized");
		const modelPath = this.modelPath;
		const generationTimeout = this.generationTimeout;

		return new ReadableStream<Uint8Array>({
			async start(controller) {
				const encoder = new TextEncoder();
				const chatId = `native-${Date.now()}`;
				let timeoutId: ReturnType<typeof setTimeout> | null = null;

				try {
					const completionPromise = context.completion(
						{
							messages: requestBody.messages,
							n_predict: requestBody.max_tokens ?? 512,
							temperature: requestBody.temperature ?? 0.7,
							top_p: requestBody.top_p ?? 0.9,
							stop: requestBody.stop,
						},
						(tokenData: any) => {
							// Emit each token as an SSE chunk in OpenAI format
							const chunk = {
								id: chatId,
								object: "chat.completion.chunk",
								created: Math.floor(Date.now() / 1000),
								model: modelPath,
								choices: [
									{
										index: 0,
										delta: { content: tokenData.token },
										finish_reason: null,
									},
								],
							};
							controller.enqueue(
								encoder.encode(`data: ${JSON.stringify(chunk)}\n\n`),
							);
						},
					);

					const timeoutPromise = new Promise<never>((_, reject) => {
						timeoutId = setTimeout(() => {
							reject(
								new Error(
									`Native generation timed out after ${generationTimeout}ms`,
								),
							);
						}, generationTimeout);
					});

					const result: any = await Promise.race([
						completionPromise,
						timeoutPromise,
					]);

					// Emit final chunk with finish_reason
					const finalChunk = {
						id: chatId,
						object: "chat.completion.chunk",
						created: Math.floor(Date.now() / 1000),
						model: modelPath,
						choices: [
							{
								index: 0,
								delta: {},
								finish_reason: result?.stopped_eos ? "stop" : "length",
							},
						],
					};
					controller.enqueue(
						encoder.encode(`data: ${JSON.stringify(finalChunk)}\n\n`),
					);
				} catch (error: any) {
					console.error("[DVAI/Native] Stream error:", error.message);
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
	 * Requires the context to be initialized with `embeddingMode: true`.
	 */
	async embedding(inputs: string | string[]): Promise<number[][]> {
		if (!this.context) throw new Error("[DVAI/Native] Context not initialized");
		if (!this.embeddingMode) {
			throw new Error(
				"[DVAI/Native] embedding() requires the context to be initialized with " +
					"embeddingMode: true. Set `nativeEmbeddingMode: true` in DVAI config.",
			);
		}
		if (typeof this.context.embedding !== "function") {
			throw new Error(
				"[DVAI/Native] The installed llama-cpp-capacitor version does not expose an " +
					"embedding() API on the context.",
			);
		}

		const inputArray = Array.isArray(inputs) ? inputs : [inputs];
		const results: number[][] = [];
		for (const text of inputArray) {
			const out: any = await this.withTimeout(
				this.context.embedding(text),
				this.generationTimeout,
			);
			// llama-cpp-capacitor may return { embedding: number[] } or number[]
			const vec = Array.isArray(out) ? out : (out?.embedding ?? out);
			results.push(vec);
		}
		return results;
	}

	/**
	 * Get the native LlamaContext instance.
	 */
	getEngine(): any {
		return this.context;
	}

	isWorkerBased(): boolean {
		return false; // Native runs on its own native thread
	}

	/**
	 * Unloads the model and frees native memory.
	 */
	async unload(): Promise<void> {
		if (this.context) {
			try {
				// Release this specific context
				await this.context.release();
			} catch (e) {
				console.warn("[DVAI/Native] Error releasing context:", e);
			}

			try {
				// Also call releaseAllLlama as a safety measure
				const mod = await import("llama-cpp-capacitor");
				await mod.releaseAllLlama();
			} catch {
				/* best effort */
			}

			this.context = null;
		}
	}

	/** Wraps a promise with a timeout. */
	private withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
		return new Promise<T>((resolve, reject) => {
			const timer = setTimeout(
				() => reject(new Error(`Native generation timed out after ${ms}ms`)),
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
}
