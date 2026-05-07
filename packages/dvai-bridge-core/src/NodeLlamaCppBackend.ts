/**
 * NodeLlamaCppBackend: Wraps `node-llama-cpp` for local inference in Node.
 *
 * - Loads a GGUF model file from disk via `getLlama()` + `loadModel()`.
 * - Exposes the same duck-typed surface as TransformersBackend / WebLLMBackend
 *   (`chatCompletion`, `createStreamingResponse`, `unload`) so the
 *   transport-agnostic handlers in `handlers/` work without changes.
 * - Streams via the LlamaChatSession's `prompt({ onTextChunk })` callback,
 *   re-shaped into OpenAI-style SSE chunks.
 * - Honors `generationTimeout` for both the blocking and streaming paths.
 *
 * Native peer dependency. `node-llama-cpp` ships its own prebuilt llama.cpp
 * binaries; consumers add it to their own `package.json`. We keep it as an
 * **optional** peer dep so the package still installs cleanly in browser-only
 * projects.
 */

export interface NodeLlamaCppBackendConfig {
	/** Absolute or relative path to a GGUF model file. Required. */
	modelPath: string;
	/** Number of GPU layers to offload (Metal on macOS, CUDA on Linux/Win). Default: 99 (max). */
	gpuLayers?: number;
	/** Number of CPU threads. Default: undefined (let node-llama-cpp pick). */
	threads?: number;
	/** Context window in tokens. Default: 2048. */
	contextSize?: number;
	/** Generation timeout in ms. Default: 60000. */
	generationTimeout?: number;
	/** Logical model identifier echoed back in OpenAI responses. Default: basename of modelPath. */
	modelId?: string;
}

export class NodeLlamaCppBackend {
	private modelPath: string;
	private gpuLayers: number;
	private threads?: number;
	private contextSize: number;
	private generationTimeout: number;
	private modelId: string;

	private llama: any = null;
	private model: any = null;
	private context: any = null;
	private session: any = null;

	/** Mirrors WebLLMBackend; not used by this backend but keeps the duck-type stable. */
	public lastFatalError: string | null = null;

	constructor(config: NodeLlamaCppBackendConfig) {
		if (!config.modelPath) {
			throw new Error(
				"[DVAI/NodeLlamaCpp] modelPath is required (path to a GGUF file).",
			);
		}
		this.modelPath = config.modelPath;
		this.gpuLayers = config.gpuLayers ?? 99;
		this.threads = config.threads;
		this.contextSize = config.contextSize ?? 2048;
		this.generationTimeout = config.generationTimeout ?? 60000;
		this.modelId =
			config.modelId ||
			this.modelPath.split(/[\\/]/).pop()?.replace(/\.gguf$/i, "") ||
			"node-llama-cpp";
	}

	clearFatalError(): void {
		this.lastFatalError = null;
	}

	async initialize(onProgress?: (info: any) => void): Promise<void> {
		let llamaModule: any;
		try {
			llamaModule = await import("node-llama-cpp");
		} catch {
			throw new Error(
				'[DVAI/NodeLlamaCpp] backend selected but "node-llama-cpp" is not installed.\n' +
					"Install it with: npm install node-llama-cpp",
			);
		}

		onProgress?.({ text: "Loading llama.cpp runtime...", progress: 0 });
		this.llama = await llamaModule.getLlama();

		onProgress?.({
			text: `Loading model: ${this.modelId}`,
			progress: 0.1,
		});
		this.model = await this.llama.loadModel({
			modelPath: this.modelPath,
			gpuLayers: this.gpuLayers,
		});

		onProgress?.({ text: "Creating context...", progress: 0.9 });
		this.context = await this.model.createContext({
			contextSize: this.contextSize,
			threads: this.threads,
		});

		this.session = new llamaModule.LlamaChatSession({
			contextSequence: this.context.getSequence(),
		});

		onProgress?.({ text: "Ready", progress: 1 });
		console.log(
			`[DVAI/NodeLlamaCpp] Loaded "${this.modelId}" (gpuLayers=${this.gpuLayers}, contextSize=${this.contextSize})`,
		);
	}

	isWorkerBased(): boolean {
		return false;
	}

	getModelId(): string {
		return this.modelId;
	}

	private withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
		return new Promise<T>((resolve, reject) => {
			const t = setTimeout(
				() => reject(new Error(`Generation timed out after ${ms}ms`)),
				ms,
			);
			p.then(
				(v) => {
					clearTimeout(t);
					resolve(v);
				},
				(e) => {
					clearTimeout(t);
					reject(e);
				},
			);
		});
	}

	/**
	 * Build a single prompt string from an OpenAI-style messages array.
	 * The session keeps its own chat history, so we collapse the *current*
	 * user-turn into one prompt and rely on node-llama-cpp's templating
	 * for everything else.
	 */
	private extractUserPrompt(messages: any[]): {
		systemPrompt?: string;
		userPrompt: string;
	} {
		const sys = messages.find((m: any) => m.role === "system");
		const lastUser = [...messages].reverse().find((m: any) => m.role === "user");
		const flatten = (c: any): string => {
			if (typeof c === "string") return c;
			if (Array.isArray(c)) return c.map(flatten).join("");
			if (c && typeof c === "object")
				return c.text || c.content || JSON.stringify(c);
			return String(c || "");
		};
		return {
			systemPrompt: sys ? flatten(sys.content) : undefined,
			userPrompt: lastUser ? flatten(lastUser.content) : "",
		};
	}

	async chatCompletion(requestBody: any): Promise<any> {
		if (!this.session) {
			throw new Error("[DVAI/NodeLlamaCpp] Backend not initialized.");
		}
		const messages = requestBody.messages || [];
		const { systemPrompt, userPrompt } = this.extractUserPrompt(messages);

		const maxTokens =
			requestBody.max_tokens ?? requestBody.max_completion_tokens ?? 256;
		const temperature = requestBody.temperature ?? 0.7;
		const topP = requestBody.top_p ?? 1.0;

		const promptOpts: any = {
			maxTokens,
			temperature,
			topP,
		};
		if (systemPrompt) promptOpts.systemPrompt = systemPrompt;

		const text: string = await this.withTimeout(
			this.session.prompt(userPrompt, promptOpts),
			this.generationTimeout,
		);

		return {
			id: `chatcmpl-${Date.now()}`,
			object: "chat.completion",
			created: Math.floor(Date.now() / 1000),
			model: this.modelId,
			choices: [
				{
					index: 0,
					message: { role: "assistant", content: text },
					finish_reason: "stop",
				},
			],
			usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
		};
	}

	createStreamingResponse(requestBody: any): ReadableStream<Uint8Array> {
		if (!this.session) {
			throw new Error("[DVAI/NodeLlamaCpp] Backend not initialized.");
		}
		const session = this.session;
		const modelId = this.modelId;
		const generationTimeout = this.generationTimeout;
		const messages = requestBody.messages || [];
		const { systemPrompt, userPrompt } = this.extractUserPrompt(messages);
		const maxTokens =
			requestBody.max_tokens ?? requestBody.max_completion_tokens ?? 256;
		const temperature = requestBody.temperature ?? 0.7;
		const topP = requestBody.top_p ?? 1.0;

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

				const enqueueFinal = (finishReason = "stop") => {
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
					const promptOpts: any = {
						maxTokens,
						temperature,
						topP,
						onTextChunk: (text: string) => {
							if (text) enqueueChunk(text);
						},
					};
					if (systemPrompt) promptOpts.systemPrompt = systemPrompt;

					await new Promise<void>((resolve, reject) => {
						timeoutId = setTimeout(
							() =>
								reject(
									new Error(
										`Generation timed out after ${generationTimeout}ms`,
									),
								),
							generationTimeout,
						);
						session.prompt(userPrompt, promptOpts).then(
							() => resolve(),
							(e: any) => reject(e),
						);
					});

					enqueueFinal("stop");
				} catch (error: any) {
					console.error(
						"[DVAI/NodeLlamaCpp] Stream error:",
						error?.message ?? error,
					);
					controller.enqueue(
						encoder.encode(
							`data: ${JSON.stringify({ error: error?.message ?? String(error) })}\n\n`,
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

	async unload(): Promise<void> {
		try {
			if (this.session && typeof this.session.dispose === "function") {
				await this.session.dispose();
			}
		} catch (_) {
			/* best effort */
		}
		try {
			if (this.context && typeof this.context.dispose === "function") {
				await this.context.dispose();
			}
		} catch (_) {
			/* best effort */
		}
		try {
			if (this.model && typeof this.model.dispose === "function") {
				await this.model.dispose();
			}
		} catch (_) {
			/* best effort */
		}
		this.session = null;
		this.context = null;
		this.model = null;
		this.llama = null;
	}
}
