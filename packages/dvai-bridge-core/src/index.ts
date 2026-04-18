import { setupWorker, type SetupWorker } from "msw/browser";
import { http, HttpResponse } from "msw";
import { LicenseValidator } from "./LicenseValidator.js";

// Re-export types from backends
export type { TransformersProgressInfo } from "./TransformersBackend.js";
export { detectWebGPU } from "./TransformersBackend.js";
export { NativeBackend } from "./NativeBackend.js";

// Re-export InitProgressReport from web-llm for backward compatibility
export type { InitProgressReport } from "@mlc-ai/web-llm";

export type BackendType = "webllm" | "transformers" | "native" | "auto";
export type DeviceType = "webgpu" | "cpu" | "auto";
export type { PipelineTask, CreatePipelineFn, PipelineCallable } from "./TransformersBackend.js";

export interface DvAIConfig {
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

	/** License key for production use. */
	licenseKey?: string;
	/** Auto-initialize on creation (React/Vanilla). Default: true */
	autoInit?: boolean;
}

/**
 * DvAI: Local AI Orchestration
 * Orchestrates WebLLM, Transformers.js, or native llama.cpp for local execution
 * and MSW for intercepting API calls with an OpenAI-compatible endpoint.
 */
export class DvAI {
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

	private validator: LicenseValidator;
	private backendInstance: any = null; // WebLLMBackend | TransformersBackend | NativeBackend
	private worker: SetupWorker | null = null;
	public isReady: boolean = false;
	/** Tracks how many consecutive recovery attempts have been made. */
	private recoveryAttempts: number = 0;

	/** The resolved backend type (after "auto" resolution). */
	private resolvedBackend: "webllm" | "transformers" | "native" = "webllm";

	constructor(config: DvAIConfig = {}) {
		this.modelId = config.modelId || "gemma-2-2b-it-q4f16_1-MLC";
		this.backend = config.backend || "webllm";
		this.transformersModelId =
			config.transformersModelId || config.modelId || "onnx-community/gemma-3n-E2B-it-ONNX";
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

		// Resolve explicit backends immediately so getActiveBackend() is correct
		// before initialize(). "auto" defers to initialize() for runtime env detection.
		if (this.backend !== "auto") {
			this.resolvedBackend = this.backend as "webllm" | "transformers" | "native";
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
				console.log("[DvAI] Auto-detected Capacitor environment → using native backend");
				return "native";
			}
			console.log("[DvAI] Auto-detected web environment → using webllm backend");
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
		if (this.resolvedBackend !== "native" && !isWorkerContext && this.serviceWorkerUrl) {
			try {
				const swRes = await fetch(this.serviceWorkerUrl, { method: "HEAD" });
				if (!swRes.ok) {
					console.warn(
						`[DvAI] Warning: Service Worker not found at "${this.serviceWorkerUrl}". ` +
							`Please run "dvai-bridge init" or "npx msw init <public_dir>" to generate it.`,
					);
				}
			} catch (e) {
				console.warn(
					`[DvAI] Could not verify Service Worker existence at "${this.serviceWorkerUrl}".`,
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
				const handlers = [
					http.post(this.mockUrl, async ({ request }: { request: Request }) => {
						if (!this.backendInstance) {
							return HttpResponse.json(
								{ error: "AI engine not initialized" },
								{ status: 503 },
							);
						}

						const requestBody = (await request.json()) as any;

						try {
							// Auto-recovery check: if WebLLM backend has a fatal error, attempt restart
							if (
								this.resolvedBackend === "webllm" &&
								this.backendInstance?.lastFatalError &&
								this.recoveryAttempts < this.maxRetries
							) {
								await this.attemptRecovery(onProgress);
							}

							if (requestBody.stream) {
								const stream =
									this.backendInstance.createStreamingResponse(requestBody);
								return new HttpResponse(stream, {
									headers: {
										"Content-Type": "text/event-stream",
										"Cache-Control": "no-cache",
										Connection: "keep-alive",
									},
								});
							} else {
								const response =
									await this.backendInstance.chatCompletion(requestBody);
								return HttpResponse.json(response);
							}
						} catch (error: any) {
							console.error("[DvAI] Error processing request:", error);

							// If this is a WebLLM fatal error and we haven't exceeded retries, attempt recovery
							if (
								this.resolvedBackend === "webllm" &&
								this.backendInstance?.lastFatalError &&
								this.recoveryAttempts < this.maxRetries
							) {
								console.log(`[DvAI] Attempting auto-recovery (${this.recoveryAttempts + 1}/${this.maxRetries})...`);
								try {
									await this.attemptRecovery(onProgress);
									// Retry the request after recovery
									if (requestBody.stream) {
										const stream =
											this.backendInstance.createStreamingResponse(requestBody);
										return new HttpResponse(stream, {
											headers: {
												"Content-Type": "text/event-stream",
												"Cache-Control": "no-cache",
												Connection: "keep-alive",
											},
										});
									} else {
										const response =
											await this.backendInstance.chatCompletion(requestBody);
										return HttpResponse.json(response);
									}
								} catch (recoveryError: any) {
									console.error("[DvAI] Recovery failed:", recoveryError.message);
								}
							}

							return HttpResponse.json({ error: error.message }, { status: 500 });
						}
					}),
				];

				this.worker = setupWorker(...handlers);
				await this.worker.start({
					onUnhandledRequest: "bypass",
					serviceWorker: {
						url: this.serviceWorkerUrl,
					},
				} as any);
			} else {
				console.log(
					`[DvAI] Skipping MSW setup (${isWorkerContext ? "Worker context" : "serviceWorkerUrl empty"}).`,
				);
			}

			this.isReady = true;
			this.recoveryAttempts = 0;
			return true;
		} catch (error) {
			console.error("[DvAI] Failed to initialize:", error);
			throw error;
		}
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
			`[DvAI] Auto-recovery: unloading engine due to "${fatalError}" (attempt ${this.recoveryAttempts}/${this.maxRetries})`,
		);

		// Unload the backend
		if (this.backendInstance) {
			try {
				await this.backendInstance.unload();
			} catch (e) {
				console.warn("[DvAI] Error during recovery unload:", e);
			}
			this.backendInstance = null;
		}

		// Reload
		await this.initializeBackend(onProgress);
		if (this.backendInstance?.clearFatalError) {
			this.backendInstance.clearFatalError();
		}
		console.log("[DvAI] Auto-recovery: engine reloaded successfully");
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
					'[DvAI] Native backend selected but "llama-cpp-capacitor" is not available.\n' +
						"Install it with: npm install llama-cpp-capacitor\n" +
						"The native backend requires a Capacitor iOS or Android app.",
				);
			}

			if (!this.nativeModelPath) {
				throw new Error(
					"[DvAI] Native backend requires a model path. Set `nativeModelPath` in config.",
				);
			}

			const backend = new NativeBackendClass({
				modelPath: this.nativeModelPath,
				contextSize: this.nativeContextSize,
				threads: this.nativeThreads,
				gpuLayers: this.nativeGpuLayers,
				generationTimeout: this.generationTimeout,
			});
			await backend.initialize(onProgress);
			this.backendInstance = backend;
			console.log(
				`[DvAI] Native backend ready (llama.cpp, threads: ${this.nativeThreads}, gpu_layers: ${this.nativeGpuLayers})`,
			);
		} else if (this.resolvedBackend === "transformers") {
			let TransformersBackend: any;
			try {
				const mod = await import("./TransformersBackend.js");
				TransformersBackend = mod.TransformersBackend;
			} catch {
				throw new Error(
					'[DvAI] Transformers.js backend selected but "@huggingface/transformers" is not installed.\n' +
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
				`[DvAI] Transformers.js backend ready (task: ${this.pipelineTask}, device: ${backend.getResolvedDevice()}, worker: ${backend.isWorkerBased()})`,
			);
		} else {
			let WebLLMBackend: any;
			try {
				const mod = await import("./WebLLMBackend.js");
				WebLLMBackend = mod.WebLLMBackend;
			} catch {
				throw new Error(
					'[DvAI] WebLLM backend selected but "@mlc-ai/web-llm" is not installed.\n' +
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
				`[DvAI] WebLLM backend ready (worker: ${backend.isWorkerBased()})`,
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
				"[DvAI] Backend not initialized. Call initialize() first.",
			);
		return this.backendInstance.chatCompletion(requestBody);
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
				"[DvAI] Backend not initialized. Call initialize() first.",
			);
		if (this.resolvedBackend !== "transformers" || !this.backendInstance.runPipeline) {
			throw new Error(
				"[DvAI] runPipeline() is only available with the Transformers.js backend.",
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
		console.log("[DvAI] Unloaded model and worker.");
	}
}

// Export a singleton instance by default, or the class for advanced usage
export const dvai: DvAI = new DvAI();
