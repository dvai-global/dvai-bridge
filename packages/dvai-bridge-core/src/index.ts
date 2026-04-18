import { setupWorker, type SetupWorker } from "msw/browser";
import { http, HttpResponse } from "msw";
import { LicenseValidator } from "./LicenseValidator.js";

// Re-export types from backends
export type { TransformersProgressInfo } from "./TransformersBackend.js";
export { detectWebGPU } from "./TransformersBackend.js";
export { NativeBackend } from "./NativeBackend.js";

// Re-export InitProgressReport from web-llm for backward compatibility
export type { InitProgressReport } from "@mlc-ai/web-llm";

/**
 * Convert an OpenAI chat.completion response body into the legacy
 * text_completion shape used by POST /v1/completions.
 * @internal Exported for testing; stable interface not guaranteed.
 */
export function chatToLegacyCompletion(chatResp: any): any {
	return {
		id:
			(chatResp.id || "").replace("chatcmpl-", "cmpl-") || `cmpl-${Date.now()}`,
		object: "text_completion",
		created: chatResp.created ?? Math.floor(Date.now() / 1000),
		model: chatResp.model,
		choices: (chatResp.choices || []).map((c: any) => ({
			text: c.message?.content ?? "",
			index: c.index ?? 0,
			finish_reason: c.finish_reason ?? "stop",
			logprobs: null,
		})),
		usage: chatResp.usage ?? {
			prompt_tokens: 0,
			completion_tokens: 0,
			total_tokens: 0,
		},
	};
}

/**
 * Wraps an SSE stream of chat.completion.chunk events and rewrites each
 * event as a legacy text_completion chunk. Preserves event boundaries.
 * @internal Exported for testing; stable interface not guaranteed.
 */
export function legacyCompletionStreamAdapter(
	chatStream: ReadableStream<Uint8Array>,
	model: string,
): ReadableStream<Uint8Array> {
	const decoder = new TextDecoder();
	const encoder = new TextEncoder();
	let buffer = "";

	return new ReadableStream<Uint8Array>({
		async start(controller) {
			const reader = chatStream.getReader();
			try {
				while (true) {
					const { done, value } = await reader.read();
					if (done) break;
					buffer += decoder.decode(value, { stream: true });

					let idx: number;
					while ((idx = buffer.indexOf("\n\n")) !== -1) {
						const rawEvent = buffer.slice(0, idx);
						buffer = buffer.slice(idx + 2);
						const dataLine = rawEvent
							.split("\n")
							.find((l) => l.startsWith("data:"));
						if (!dataLine) continue;
						const payload = dataLine.slice("data:".length).trim();
						if (payload === "[DONE]") {
							controller.enqueue(encoder.encode("data: [DONE]\n\n"));
							continue;
						}
						try {
							const chunk = JSON.parse(payload);
							const legacyChunk = {
								id: (chunk.id || "").replace("chatcmpl-", "cmpl-"),
								object: "text_completion.chunk",
								created: chunk.created,
								model: chunk.model || model,
								choices: (chunk.choices || []).map((c: any) => ({
									text: c.delta?.content ?? "",
									index: c.index ?? 0,
									finish_reason: c.finish_reason ?? null,
									logprobs: null,
								})),
							};
							controller.enqueue(
								encoder.encode(`data: ${JSON.stringify(legacyChunk)}\n\n`),
							);
						} catch {
							// Forward raw payload if JSON parsing fails (e.g., error events)
							controller.enqueue(encoder.encode(`data: ${payload}\n\n`));
						}
					}
				}
			} finally {
				controller.close();
			}
		},
	});
}

export type BackendType = "webllm" | "transformers" | "native" | "auto";
export type DeviceType = "webgpu" | "cpu" | "auto";
export type {
	PipelineTask,
	CreatePipelineFn,
	PipelineCallable,
} from "./TransformersBackend.js";

export interface DVAIConfig {
	/** The model ID for web-llm backend. Default: "gemma-2-2b-it-q4f16_1-MLC" */
	modelId?: string;
	/** The backend engine to use. Default: "webllm". Set to "auto" to auto-detect (native on Capacitor, webllm otherwise). */
	backend?: BackendType;
	/** HuggingFace model ID for Transformers.js backend. Default: "onnx-community/gemma-3n-E2B-it-ONNX" */
	transformersModelId?: string;
	/** Pipeline task for Transformers.js (e.g. "text-generation", "text-to-image", "automatic-speech-recognition"). Default: "text-generation" */
	pipelineTask?: string;
	/** Device for Transformers.js - "webgpu", "cpu", or "auto" (detect). Default: "auto" */
	device?: DeviceType;
	/** Quantization for Transformers.js (e.g. "q4", "q8", "f16"). Default: undefined */
	dtype?: string;
	/** Generation timeout in ms. Default: 60000 (60s) */
	generationTimeout?: number;
	/** Maximum consecutive blank chunks before aborting stream (WebLLM). Default: 20 */
	maxBlankChunks?: number;
	/** Maximum auto-recovery retries on fatal WebLLM errors (blank output/timeout). Default: 2 */
	maxRetries?: number;
	/** Mock URL for MSW interception. Default: "https://api.openai.local/v1/chat/completions" */
	mockUrl?: string;
	/** Path to the MSW service worker script. Default: "/mockServiceWorker.js" */
	serviceWorkerUrl?: string;
	/** URL to the WebLLM worker script (for offloading inference). Default: "/dvai-webllm.worker.js" */
	webllmWorkerUrl?: string;
	/** URL to the Transformers.js worker script (for offloading inference). Default: "/dvai-transformers.worker.js" */
	transformersWorkerUrl?: string;
	/**
	 * Custom pipeline factory for Transformers.js backend.
	 * When provided, replaces the default pipeline() call with your own
	 * model loading and inference logic. Must return a callable that accepts
	 * (messages, options) and returns [{ generated_text: string }].
	 */
	createPipeline?: import("./TransformersBackend.js").CreatePipelineFn;

	// --- Native backend (llama-cpp-capacitor) options ---
	/** Path to the GGUF model file for native backend. Required when using backend: "native". */
	nativeModelPath?: string;
	/** Number of GPU layers for native backend (iOS Metal). Default: 99 (max) */
	nativeGpuLayers?: number;
	/** Number of CPU threads for native backend. Default: 4 */
	nativeThreads?: number;
	/** Context window size for native backend. Default: 2048 */
	nativeContextSize?: number;
	/**
	 * Initialize the native llama.cpp context in embedding mode. Required for
	 * `/v1/embeddings` to work on the native backend. When true, the context
	 * should be a dedicated embedding model and will typically not be usable
	 * for chat/completion. Default: false.
	 */
	nativeEmbeddingMode?: boolean;

	/** License key for production use. */
	licenseKey?: string;
	/** Auto-initialize on creation (React/Vanilla). Default: true */
	autoInit?: boolean;
}

/**
 * DVAI: Local AI Orchestration
 * Orchestrates WebLLM, Transformers.js, or native llama.cpp for local execution
 * and MSW for intercepting API calls with an OpenAI-compatible endpoint.
 */
export class DVAI {
	public modelId: string;
	public mockUrl: string;
	public serviceWorkerUrl: string;
	public licenseKey?: string;
	public backend: BackendType;
	public transformersModelId: string;
	public pipelineTask: string;
	public device: DeviceType;
	public generationTimeout: number;
	public maxBlankChunks: number;
	public maxRetries: number;
	public webllmWorkerUrl: string;
	public transformersWorkerUrl: string;
	public dtype?: string;
	public createPipeline?: import("./TransformersBackend.js").CreatePipelineFn;

	// Native backend options
	public nativeModelPath: string;
	public nativeGpuLayers: number;
	public nativeThreads: number;
	public nativeContextSize: number;
	public nativeEmbeddingMode: boolean;

	private validator: LicenseValidator;
	private backendInstance: any = null; // WebLLMBackend | TransformersBackend | NativeBackend
	private worker: SetupWorker | null = null;
	public isReady: boolean = false;
	/** Tracks how many consecutive recovery attempts have been made. */
	private recoveryAttempts: number = 0;

	/** The resolved backend type (after "auto" resolution). */
	private resolvedBackend: "webllm" | "transformers" | "native" = "webllm";

	constructor(config: DVAIConfig = {}) {
		this.modelId = config.modelId || "gemma-2-2b-it-q4f16_1-MLC";
		this.backend = config.backend || "webllm";
		this.transformersModelId =
			config.transformersModelId ||
			config.modelId ||
			"onnx-community/gemma-3n-E2B-it-ONNX";
		this.pipelineTask = config.pipelineTask || "text-generation";
		this.device = config.device || "auto";
		this.dtype = config.dtype;
		this.createPipeline = config.createPipeline;
		this.generationTimeout = config.generationTimeout ?? 60000;
		this.maxBlankChunks = config.maxBlankChunks ?? 20;
		this.maxRetries = config.maxRetries ?? 2;
		this.webllmWorkerUrl = config.webllmWorkerUrl ?? "/dvai-webllm.worker.js";
		this.transformersWorkerUrl =
			config.transformersWorkerUrl ?? "/dvai-transformers.worker.js";
		this.mockUrl =
			config.mockUrl ?? "https://api.openai.local/v1/chat/completions";
		this.serviceWorkerUrl = config.serviceWorkerUrl ?? "/mockServiceWorker.js";
		this.licenseKey = config.licenseKey;
		this.validator = new LicenseValidator({ licenseKey: this.licenseKey });

		// Native backend options
		this.nativeModelPath = config.nativeModelPath || "";
		this.nativeGpuLayers = config.nativeGpuLayers ?? 99;
		this.nativeThreads = config.nativeThreads ?? 4;
		this.nativeContextSize = config.nativeContextSize ?? 2048;
		this.nativeEmbeddingMode = config.nativeEmbeddingMode ?? false;

		// Resolve explicit backends immediately so getActiveBackend() is correct
		// before initialize(). "auto" defers to initialize() for runtime env detection.
		if (this.backend !== "auto") {
			this.resolvedBackend = this.backend as
				| "webllm"
				| "transformers"
				| "native";
		}
	}

	/**
	 * Returns the active backend type (resolved from "auto" if applicable).
	 */
	getActiveBackend(): "webllm" | "transformers" | "native" {
		return this.resolvedBackend;
	}

	/**
	 * Resolves the "auto" backend to a concrete type based on environment.
	 */
	private resolveBackend(): "webllm" | "transformers" | "native" {
		if (this.backend === "auto") {
			// Auto-detect: use native on Capacitor, webllm on web
			const isCapacitor =
				typeof window !== "undefined" &&
				!!(window as any).Capacitor?.isNativePlatform?.();
			if (isCapacitor) {
				console.log(
					"[DVAI] Auto-detected Capacitor environment → using native backend",
				);
				return "native";
			}
			console.log(
				"[DVAI] Auto-detected web environment → using webllm backend",
			);
			return "webllm";
		}
		return this.backend as "webllm" | "transformers" | "native";
	}

	/**
	 * Initializes the MSW Service Worker and the selected backend engine.
	 * @param onProgress - Callback for model download progress
	 */
	async initialize(
		onProgress: (info: any) => void = console.log,
	): Promise<boolean> {
		if (this.isReady) return true;

		// Resolve "auto" backend
		this.resolvedBackend = this.resolveBackend();

		// 0. Validate License for Commercial/Production use
		await this.validator.validate();

		// Detect Web Worker context — MSW (service workers) are unavailable inside Web Workers.
		const isWorkerContext =
			typeof window === "undefined" &&
			typeof self !== "undefined" &&
			typeof (self as any).importScripts === "function";

		// 0.1 Verify Service Worker Reachability (Quality of Life) — skip for native backend,
		// skip when inside a Worker context, and skip when serviceWorkerUrl is empty (MSW disabled).
		if (
			this.resolvedBackend !== "native" &&
			!isWorkerContext &&
			this.serviceWorkerUrl
		) {
			try {
				const swRes = await fetch(this.serviceWorkerUrl, { method: "HEAD" });
				if (!swRes.ok) {
					console.warn(
						`[DVAI] Warning: Service Worker not found at "${this.serviceWorkerUrl}". ` +
							`Please run "dvai-bridge init" or "npx msw init <public_dir>" to generate it.`,
					);
				}
			} catch (e) {
				console.warn(
					`[DVAI] Could not verify Service Worker existence at "${this.serviceWorkerUrl}".`,
				);
			}
		}

		try {
			// 1. Initialize the selected backend (lazy import)
			await this.initializeBackend(onProgress);

			// 2. Setup MSW worker to intercept requests.
			// Skip when inside a Web Worker (navigator.serviceWorker is unavailable)
			// or when serviceWorkerUrl is explicitly empty (MSW disabled).
			if (!isWorkerContext && this.serviceWorkerUrl) {
				const handlers = this.buildMswHandlers(onProgress);

				this.worker = setupWorker(...handlers);
				await this.worker.start({
					onUnhandledRequest: "bypass",
					serviceWorker: {
						url: this.serviceWorkerUrl,
					},
				} as any);
			} else {
				console.log(
					`[DVAI] Skipping MSW setup (${isWorkerContext ? "Worker context" : "serviceWorkerUrl empty"}).`,
				);
			}

			this.isReady = true;
			this.recoveryAttempts = 0;
			return true;
		} catch (error) {
			console.error("[DVAI] Failed to initialize:", error);
			throw error;
		}
	}

	/**
	 * Computes the set of OpenAI-compatible endpoint URLs, derived from `mockUrl`.
	 * If `mockUrl` ends with "/chat/completions", the base is taken as its parent;
	 * otherwise the parent segment of `mockUrl` is used as the base.
	 */
	private getEndpoints(): {
		chat: string;
		completions: string;
		embeddings: string;
		models: string;
	} {
		const chat = this.mockUrl;
		let base = chat;
		const chatSuffix = "/chat/completions";
		if (chat.endsWith(chatSuffix)) {
			base = chat.slice(0, -chatSuffix.length);
		} else {
			try {
				const u = new URL(chat);
				const parts = u.pathname.split("/").filter(Boolean);
				parts.pop();
				u.pathname = "/" + parts.join("/");
				base = u.toString().replace(/\/$/, "");
			} catch {
				/* keep base = chat */
			}
		}
		return {
			chat,
			completions: `${base}/completions`,
			embeddings: `${base}/embeddings`,
			models: `${base}/models`,
		};
	}

	/**
	 * Build the list of MSW handlers for all supported OpenAI-compatible endpoints.
	 */
	private buildMswHandlers(onProgress: (info: any) => void): any[] {
		const urls = this.getEndpoints();
		const self = this;

		const handleChatCompletion = async (
			request: Request,
		): Promise<Response> => {
			if (!self.backendInstance) {
				return HttpResponse.json(
					{ error: "AI engine not initialized" },
					{ status: 503 },
				);
			}
			const requestBody = (await request.json()) as any;

			const runOnce = async (): Promise<Response> => {
				if (requestBody.stream) {
					const stream =
						self.backendInstance.createStreamingResponse(requestBody);
					return new HttpResponse(stream, {
						headers: {
							"Content-Type": "text/event-stream",
							"Cache-Control": "no-cache",
							Connection: "keep-alive",
						},
					});
				}
				const response = await self.backendInstance.chatCompletion(requestBody);
				return HttpResponse.json(response);
			};

			try {
				if (
					self.resolvedBackend === "webllm" &&
					self.backendInstance?.lastFatalError &&
					self.recoveryAttempts < self.maxRetries
				) {
					await self.attemptRecovery(onProgress);
				}
				return await runOnce();
			} catch (error: any) {
				console.error("[DVAI] Error processing request:", error);

				if (
					self.resolvedBackend === "webllm" &&
					self.backendInstance?.lastFatalError &&
					self.recoveryAttempts < self.maxRetries
				) {
					console.log(
						`[DVAI] Attempting auto-recovery (${self.recoveryAttempts + 1}/${self.maxRetries})...`,
					);
					try {
						await self.attemptRecovery(onProgress);
						return await runOnce();
					} catch (recoveryError: any) {
						console.error("[DVAI] Recovery failed:", recoveryError.message);
					}
				}

				return HttpResponse.json({ error: error.message }, { status: 500 });
			}
		};

		const handleCompletion = async (request: Request): Promise<Response> => {
			if (!self.backendInstance) {
				return HttpResponse.json(
					{ error: "AI engine not initialized" },
					{ status: 503 },
				);
			}
			const body = (await request.json()) as any;
			const promptField = body.prompt;
			const prompt = Array.isArray(promptField)
				? promptField.join("\n")
				: (promptField ?? "");
			const chatBody = {
				...body,
				messages: [{ role: "user", content: prompt }],
			};
			delete chatBody.prompt;

			try {
				if (chatBody.stream) {
					const chatStream =
						self.backendInstance.createStreamingResponse(chatBody);
					const legacyStream = legacyCompletionStreamAdapter(
						chatStream,
						body.model || self.modelId,
					);
					return new HttpResponse(legacyStream, {
						headers: {
							"Content-Type": "text/event-stream",
							"Cache-Control": "no-cache",
							Connection: "keep-alive",
						},
					});
				}
				const chatResp = await self.backendInstance.chatCompletion(chatBody);
				return HttpResponse.json(chatToLegacyCompletion(chatResp));
			} catch (error: any) {
				console.error("[DVAI] Error processing /v1/completions:", error);
				return HttpResponse.json({ error: error.message }, { status: 500 });
			}
		};

		const handleEmbeddings = async (request: Request): Promise<Response> => {
			if (!self.backendInstance) {
				return HttpResponse.json(
					{ error: "AI engine not initialized" },
					{ status: 503 },
				);
			}
			if (self.resolvedBackend === "webllm") {
				return HttpResponse.json(
					{
						error:
							"Embeddings are not supported on the WebLLM backend. " +
							"Use backend: 'transformers' with pipelineTask: 'feature-extraction', " +
							"or backend: 'native' with nativeEmbeddingMode: true.",
					},
					{ status: 400 },
				);
			}
			if (typeof self.backendInstance.embedding !== "function") {
				return HttpResponse.json(
					{
						error:
							"The current backend does not support embeddings. " +
							"For transformers: use pipelineTask: 'feature-extraction'. " +
							"For native: set nativeEmbeddingMode: true.",
					},
					{ status: 400 },
				);
			}

			const body = (await request.json()) as any;
			const input = body.input;
			if (input === undefined || input === null) {
				return HttpResponse.json(
					{ error: "Missing 'input' field." },
					{ status: 400 },
				);
			}

			try {
				const vectors: number[][] = await self.backendInstance.embedding(input);
				return HttpResponse.json({
					object: "list",
					data: vectors.map((v, i) => ({
						object: "embedding",
						embedding: v,
						index: i,
					})),
					model:
						body.model ||
						(self.resolvedBackend === "transformers"
							? self.transformersModelId
							: self.resolvedBackend === "native"
								? self.nativeModelPath
								: self.modelId),
					usage: { prompt_tokens: 0, total_tokens: 0 },
				});
			} catch (error: any) {
				console.error("[DVAI] Error processing /v1/embeddings:", error);
				return HttpResponse.json({ error: error.message }, { status: 500 });
			}
		};

		const handleModels = async (): Promise<Response> => {
			const id =
				self.resolvedBackend === "transformers"
					? self.transformersModelId
					: self.resolvedBackend === "native"
						? self.nativeModelPath
						: self.modelId;
			return HttpResponse.json({
				object: "list",
				data: [
					{
						id,
						object: "model",
						created: Math.floor(Date.now() / 1000),
						owned_by: "dvai-bridge",
					},
				],
			});
		};

		return [
			http.post(urls.chat, async ({ request }: { request: Request }) =>
				handleChatCompletion(request),
			),
			http.post(urls.completions, async ({ request }: { request: Request }) =>
				handleCompletion(request),
			),
			http.post(urls.embeddings, async ({ request }: { request: Request }) =>
				handleEmbeddings(request),
			),
			http.get(urls.models, async () => handleModels()),
		];
	}

	/**
	 * Attempts to recover from a fatal WebLLM error by unloading and reloading the backend.
	 */
	private async attemptRecovery(
		onProgress: (info: any) => void,
	): Promise<void> {
		this.recoveryAttempts++;
		const fatalError = this.backendInstance?.lastFatalError;
		console.log(
			`[DVAI] Auto-recovery: unloading engine due to "${fatalError}" (attempt ${this.recoveryAttempts}/${this.maxRetries})`,
		);

		// Unload the backend
		if (this.backendInstance) {
			try {
				await this.backendInstance.unload();
			} catch (e) {
				console.warn("[DVAI] Error during recovery unload:", e);
			}
			this.backendInstance = null;
		}

		// Reload
		await this.initializeBackend(onProgress);
		if (this.backendInstance?.clearFatalError) {
			this.backendInstance.clearFatalError();
		}
		console.log("[DVAI] Auto-recovery: engine reloaded successfully");
	}

	/**
	 * Lazy-imports and initializes the selected backend.
	 */
	private async initializeBackend(
		onProgress: (info: any) => void,
	): Promise<void> {
		if (this.resolvedBackend === "native") {
			let NativeBackendClass: any;
			try {
				const mod = await import("./NativeBackend.js");
				NativeBackendClass = mod.NativeBackend;
			} catch {
				throw new Error(
					'[DVAI] Native backend selected but "llama-cpp-capacitor" is not available.\n' +
						"Install it with: npm install llama-cpp-capacitor\n" +
						"The native backend requires a Capacitor iOS or Android app.",
				);
			}

			if (!this.nativeModelPath) {
				throw new Error(
					"[DVAI] Native backend requires a model path. Set `nativeModelPath` in config.",
				);
			}

			const backend = new NativeBackendClass({
				modelPath: this.nativeModelPath,
				contextSize: this.nativeContextSize,
				threads: this.nativeThreads,
				gpuLayers: this.nativeGpuLayers,
				generationTimeout: this.generationTimeout,
				embeddingMode: this.nativeEmbeddingMode,
			});
			await backend.initialize(onProgress);
			this.backendInstance = backend;
			console.log(
				`[DVAI] Native backend ready (llama.cpp, threads: ${this.nativeThreads}, gpu_layers: ${this.nativeGpuLayers})`,
			);
		} else if (this.resolvedBackend === "transformers") {
			let TransformersBackend: any;
			try {
				const mod = await import("./TransformersBackend.js");
				TransformersBackend = mod.TransformersBackend;
			} catch {
				throw new Error(
					'[DVAI] Transformers.js backend selected but "@huggingface/transformers" is not installed.\n' +
						"Install it with: npm install @huggingface/transformers",
				);
			}
			const backend = new TransformersBackend({
				modelId: this.transformersModelId,
				device: this.device,
				generationTimeout: this.generationTimeout,
				workerUrl: this.transformersWorkerUrl,
				pipelineTask: this.pipelineTask,
				dtype: this.dtype,
				createPipeline: this.createPipeline,
			});
			await backend.initialize(onProgress);
			this.backendInstance = backend;
			console.log(
				`[DVAI] Transformers.js backend ready (task: ${this.pipelineTask}, device: ${backend.getResolvedDevice()}, worker: ${backend.isWorkerBased()})`,
			);
		} else {
			let WebLLMBackend: any;
			try {
				const mod = await import("./WebLLMBackend.js");
				WebLLMBackend = mod.WebLLMBackend;
			} catch {
				throw new Error(
					'[DVAI] WebLLM backend selected but "@mlc-ai/web-llm" is not installed.\n' +
						"Install it with: npm install @mlc-ai/web-llm",
				);
			}
			const backend = new WebLLMBackend({
				modelId: this.modelId,
				generationTimeout: this.generationTimeout,
				maxBlankChunks: this.maxBlankChunks,
				workerUrl: this.webllmWorkerUrl,
			});
			await backend.initialize(onProgress);
			this.backendInstance = backend;
			console.log(
				`[DVAI] WebLLM backend ready (worker: ${backend.isWorkerBased()})`,
			);
		}
	}

	/**
	 * Gets the underlying engine instance directly.
	 * - For WebLLM: returns the MLCEngine
	 * - For Transformers.js: returns the pipeline
	 * - For Native: returns the LlamaContext
	 */
	getEngine(): any {
		if (!this.backendInstance) return null;
		if (this.resolvedBackend === "webllm") {
			return this.backendInstance.getEngine?.() ?? null;
		}
		if (this.resolvedBackend === "native") {
			return this.backendInstance.getEngine?.() ?? null;
		}
		return this.backendInstance.getPipeline?.() ?? null;
	}

	/**
	 * Gets the MSW worker instance directly if needed.
	 */
	getWorker(): SetupWorker | null {
		return this.worker;
	}

	/**
	 * Perform a direct chat completion (bypasses MSW, calls backend directly).
	 * Useful for programmatic usage without going through the fetch mock.
	 */
	async chatCompletion(requestBody: any): Promise<any> {
		if (!this.backendInstance)
			throw new Error(
				"[DVAI] Backend not initialized. Call initialize() first.",
			);
		return this.backendInstance.chatCompletion(requestBody);
	}

	/**
	 * Generate embeddings for one or more text inputs.
	 *
	 * Supported when:
	 * - backend is "transformers" with pipelineTask: "feature-extraction"
	 * - backend is "native" with nativeEmbeddingMode: true
	 *
	 * Throws when called on the WebLLM backend.
	 *
	 * @param inputs - A single string or array of strings to embed
	 * @returns An array of embedding vectors (one per input)
	 */
	async embedding(inputs: string | string[]): Promise<number[][]> {
		if (!this.backendInstance)
			throw new Error(
				"[DVAI] Backend not initialized. Call initialize() first.",
			);
		if (this.resolvedBackend === "webllm") {
			throw new Error(
				"[DVAI] Embeddings are not supported on the WebLLM backend. " +
					"Use backend: 'transformers' with pipelineTask: 'feature-extraction', " +
					"or backend: 'native' with nativeEmbeddingMode: true.",
			);
		}
		if (typeof this.backendInstance.embedding !== "function") {
			throw new Error(
				"[DVAI] The current backend does not expose an embedding() method.",
			);
		}
		return this.backendInstance.embedding(inputs);
	}

	/**
	 * Run the pipeline directly (Transformers.js only).
	 * Use this for non-text tasks like text-to-image, ASR, text-to-speech, etc.
	 * @param inputs - Input data appropriate for the pipeline task
	 * @param options - Pipeline-specific options
	 */
	async runPipeline(inputs: any, options?: Record<string, any>): Promise<any> {
		if (!this.backendInstance)
			throw new Error(
				"[DVAI] Backend not initialized. Call initialize() first.",
			);
		if (
			this.resolvedBackend !== "transformers" ||
			!this.backendInstance.runPipeline
		) {
			throw new Error(
				"[DVAI] runPipeline() is only available with the Transformers.js backend.",
			);
		}
		return this.backendInstance.runPipeline(inputs, options);
	}

	/**
	 * Unloads the AI engine and stops the MSW worker to free up resources.
	 */
	async unload(): Promise<void> {
		if (this.backendInstance) {
			await this.backendInstance.unload();
			this.backendInstance = null;
		}

		if (this.worker) {
			this.worker.stop();
			this.worker = null;
		}

		this.isReady = false;
		this.recoveryAttempts = 0;
		console.log("[DVAI] Unloaded model and worker.");
	}
}

// Export a singleton instance by default, or the class for advanced usage
export const dvai: DVAI = new DVAI();
