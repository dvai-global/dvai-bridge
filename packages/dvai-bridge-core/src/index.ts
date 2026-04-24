import { LicenseValidator } from "./LicenseValidator.js";
import { type HandlerContext } from "./handlers/index.js";

// Re-export types from backends
export type { TransformersProgressInfo } from "./TransformersBackend.js";
export { detectWebGPU } from "./TransformersBackend.js";
export { NativeBackend } from "./NativeBackend.js";

// Re-export InitProgressReport from web-llm for backward compatibility
export type { InitProgressReport } from "@mlc-ai/web-llm";

// Re-export legacy helpers from the handlers module for backward compat.
// Existing tests/consumers import these from "@dvai-bridge/core".
export {
	chatToLegacyCompletion,
	legacyCompletionStreamAdapter,
} from "./handlers/completions.js";

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
	 * MAIN-THREAD ONLY — function closures don't cross the Worker boundary.
	 * When provided, replaces the default pipeline() call with your own
	 * model loading and inference logic. Must return a callable that accepts
	 * (messages, options) and returns [{ generated_text: string }].
	 *
	 * For multimodal models that should run in the worker (recommended),
	 * use the declarative `transformersModelClass` / `transformersProcessorClass`
	 * / `transformersDisableEncoders` config instead.
	 */
	createPipeline?: import("./TransformersBackend.js").CreatePipelineFn;
	/**
	 * Name of a transformers.js export to use as the model class (loaded via
	 * `ClassName.from_pretrained(modelId)`). Enables the declarative
	 * multimodal loader — works in the worker AND on main thread so the
	 * same config ships correctly regardless of path.
	 *
	 * Examples: "Gemma4ForConditionalGeneration", "LlavaForConditionalGeneration",
	 * "AutoModelForCausalLM". Leave unset to use the generic `pipeline()` factory.
	 */
	transformersModelClass?: string;
	/**
	 * Processor class name for the declarative loader. Default: "AutoProcessor".
	 * Only used when `transformersModelClass` is set.
	 */
	transformersProcessorClass?: string;
	/**
	 * Model submodule fields to null out after load, e.g. `["vision_encoder"]`
	 * for a voice-only host app using a multimodal checkpoint. Purely
	 * declarative — dvai-bridge walks the list and nulls each named field
	 * if present; unknown/absent names are silently ignored. Host apps
	 * control this based on their own criteria.
	 */
	transformersDisableEncoders?: string[];

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

	/**
	 * Which transport to use for the OpenAI-compatible surface.
	 * - "auto"  (default) → msw in browser, http in Node, none in workers
	 * - "msw"  → force MSW (browser only; errors elsewhere)
	 * - "http" → force HTTP server (Node only; errors elsewhere)
	 * - "none" → no transport; use dvai.chatCompletion() directly
	 */
	transport?: "auto" | "msw" | "http" | "none";

	/** HTTP-only. Base port. Default: 38883. */
	httpBasePort?: number;

	/** HTTP-only. Max port-fallback attempts. Default: 16. */
	httpMaxPortAttempts?: number;

	/**
	 * HTTP-only. Controls the Access-Control-Allow-Origin response header.
	 * - "*"               → echo "*" (default; dev-friendly)
	 * - "https://x.com"   → echo that exact origin
	 * - ["a.com","b.com"] → match the request's Origin header against the
	 *                        list; echo the matched value. Requests from
	 *                        unlisted origins get ACAO omitted.
	 */
	corsOrigin?: string | string[];
}

/**
 * DVAI: Local AI Orchestration
 * Orchestrates WebLLM, Transformers.js, or native llama.cpp for local
 * inference and selects an MSW or HTTP transport (auto-detected from
 * environment) to expose the OpenAI-compatible endpoint. Read
 * `dvai.baseUrl` after initialize() to get the URL to point any OpenAI
 * SDK at.
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
	public transformersModelClass?: string;
	public transformersProcessorClass?: string;
	public transformersDisableEncoders?: string[];

	// Native backend options
	public nativeModelPath: string;
	public nativeGpuLayers: number;
	public nativeThreads: number;
	public nativeContextSize: number;
	public nativeEmbeddingMode: boolean;

	/** Raw transport config (e.g., "auto"). */
	public transport: "auto" | "msw" | "http" | "none";
	public httpBasePort: number;
	public httpMaxPortAttempts: number;
	public corsOrigin: string | string[];

	/** Resolved transport kind after selectTransport() runs. */
	private resolvedTransport: "msw" | "http" | "none" = "none";

	/** Populated after transport.start(). Undefined on "none". */
	public baseUrl?: string;
	public port?: number;

	/** Active transport instance; null before initialize() / after unload(). */
	private activeTransport: import("./transports/index.js").Transport | null =
		null;

	private validator: LicenseValidator;
	private backendInstance: any = null; // WebLLMBackend | TransformersBackend | NativeBackend
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
		this.transformersModelClass = config.transformersModelClass;
		this.transformersProcessorClass = config.transformersProcessorClass;
		this.transformersDisableEncoders = config.transformersDisableEncoders;
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

		// Transport options
		this.transport = config.transport ?? "auto";
		this.httpBasePort = config.httpBasePort ?? 38883;
		this.httpMaxPortAttempts = config.httpMaxPortAttempts ?? 16;
		this.corsOrigin = config.corsOrigin ?? "*";

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

	/** Returns the resolved transport kind (after "auto" resolution). */
	getActiveTransport(): "msw" | "http" | "none" {
		return this.resolvedTransport;
	}

	/** Returns the base URL a host app hands to an OpenAI SDK. */
	getBaseUrl(): string | undefined {
		return this.baseUrl;
	}

	/** Returns the HTTP port bound (http transport only). */
	getPort(): number | undefined {
		return this.port;
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
	 * Initializes the selected backend engine and starts the resolved
	 * transport (MSW in browsers, HTTP server in Node, or none).
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

			// 2. Select transport based on env + config
			const { selectTransport, MswTransport, HttpTransport } = await import(
				"./transports/index.js"
			);
			this.resolvedTransport = selectTransport({
				transport: this.transport === "auto" ? undefined : this.transport,
				serviceWorkerUrl: this.serviceWorkerUrl,
			});

			// Warn if mockUrl was explicitly customized under HTTP (will be ignored).
			// The default value is used as the sentinel for "user did not customize".
			if (
				this.resolvedTransport === "http" &&
				this.mockUrl !== "https://api.openai.local/v1/chat/completions"
			) {
				console.warn(
					"[DVAI] mockUrl config is ignored under transport=\"http\". " +
						"The HTTP server always serves at /v1/*. Use dvai.baseUrl " +
						"to get the exact endpoint.",
				);
			}

			// Warn if serviceWorkerUrl is empty but transport="msw" was forced
			if (
				this.resolvedTransport === "msw" &&
				this.serviceWorkerUrl === "" &&
				this.transport === "msw"
			) {
				console.warn(
					"[DVAI] serviceWorkerUrl is empty but transport='msw' was requested; MSW will fail to register.",
				);
			}

			// Worker-context informational message
			if (
				this.resolvedTransport === "none" &&
				typeof window === "undefined" &&
				typeof self !== "undefined"
			) {
				console.log(
					"[DVAI] Running in a Web Worker — no transport started. " +
						"Use dvai.chatCompletion() directly, or register MSW on the main thread.",
				);
			}

			// Construct + start the transport
			if (this.resolvedTransport === "msw") {
				this.activeTransport = new MswTransport({
					mockUrl: this.mockUrl,
					serviceWorkerUrl: this.serviceWorkerUrl,
				});
			} else if (this.resolvedTransport === "http") {
				this.activeTransport = new HttpTransport({
					httpBasePort: this.httpBasePort,
					httpMaxPortAttempts: this.httpMaxPortAttempts,
					corsOrigin: this.corsOrigin,
				});
			} else {
				this.activeTransport = null;
			}

			if (this.activeTransport) {
				const ctx = this.getHandlerContext(onProgress);
				const started = await this.activeTransport.start(ctx);
				this.baseUrl = started.baseUrl;
				this.port = started.port;
			} else {
				this.baseUrl = undefined;
				this.port = undefined;
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
	 * Builds a HandlerContext consumed by the transport-agnostic handlers.
	 * `backend` is exposed via a getter so that when recovery replaces
	 * `this.backendInstance` mid-request, the handler's subsequent reads of
	 * `ctx.backend` see the new instance (critical for the reactive-recovery
	 * retry path in handleChatCompletion).
	 */
	private getHandlerContext(
		onProgress: (info: any) => void,
	): HandlerContext {
		const self = this;
		return {
			get backend() {
				return self.backendInstance;
			},
			resolvedBackend: this.resolvedBackend,
			modelId:
				this.resolvedBackend === "transformers"
					? this.transformersModelId
					: this.resolvedBackend === "native"
						? this.nativeModelPath
						: this.modelId,
			onRecovery:
				this.resolvedBackend === "webllm"
					? async () => {
							if (
								this.backendInstance?.lastFatalError &&
								this.recoveryAttempts < this.maxRetries
							) {
								await this.attemptRecovery(onProgress);
							} else if (this.recoveryAttempts >= this.maxRetries) {
								throw new Error("Recovery exhausted");
							}
						}
					: undefined,
		};
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
				modelClass: this.transformersModelClass,
				processorClass: this.transformersProcessorClass,
				disableEncoders: this.transformersDisableEncoders,
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
	 * Unloads the AI engine and stops the active transport to free up resources.
	 */
	async unload(): Promise<void> {
		if (this.backendInstance) {
			await this.backendInstance.unload();
			this.backendInstance = null;
		}
		if (this.activeTransport) {
			await this.activeTransport.stop();
			this.activeTransport = null;
		}
		this.baseUrl = undefined;
		this.port = undefined;
		this.isReady = false;
		this.recoveryAttempts = 0;
		console.log("[DVAI] Unloaded model and transport.");
	}
}

// Export a singleton instance by default, or the class for advanced usage
export const dvai: DVAI = new DVAI();
