import {
	dvai,
	DVAI,
	type DVAIConfig,
	type BackendType,
} from "@dvai-bridge/core";

export type { DVAIConfig, BackendType } from "@dvai-bridge/core";

export interface VanillaState {
	isReady: boolean;
	progress: string;
	mockUrl: string;
	modelId: string;
	backend: BackendType;
}

export type VanillaListener = (state: VanillaState) => void;

/**
 * VanillaDVAI: A simple wrapper for dvai-bridge-core to be used in vanilla JS applications.
 */
export class VanillaDVAI {
	private core: DVAI;
	private isReady: boolean = false;
	private progressText: string = "";
	private mockUrl: string;
	private modelId: string;
	private backend: BackendType;
	private listeners: Set<VanillaListener> = new Set();

	constructor(config: DVAIConfig = {}) {
		this.core = dvai; // Default to singleton
		// Apply config to singleton
		if (Object.keys(config).length > 0) {
			if (config.modelId) this.core.modelId = config.modelId;
			if (config.mockUrl) this.core.mockUrl = config.mockUrl;
			if (config.serviceWorkerUrl)
				this.core.serviceWorkerUrl = config.serviceWorkerUrl;
			if (config.backend) this.core.backend = config.backend;
			if (config.transformersModelId)
				this.core.transformersModelId = config.transformersModelId;
			if (config.device) this.core.device = config.device;
			if (config.generationTimeout !== undefined)
				this.core.generationTimeout = config.generationTimeout;
			if (config.maxBlankChunks !== undefined)
				this.core.maxBlankChunks = config.maxBlankChunks;
			if (config.maxRetries !== undefined)
				this.core.maxRetries = config.maxRetries;
			if (config.pipelineTask) this.core.pipelineTask = config.pipelineTask;
			if (config.webllmWorkerUrl)
				this.core.webllmWorkerUrl = config.webllmWorkerUrl;
			if (config.transformersWorkerUrl)
				this.core.transformersWorkerUrl = config.transformersWorkerUrl;
			// Native backend config
			if (config.nativeModelPath)
				this.core.nativeModelPath = config.nativeModelPath;
			if (config.nativeGpuLayers !== undefined)
				this.core.nativeGpuLayers = config.nativeGpuLayers;
			if (config.nativeThreads !== undefined)
				this.core.nativeThreads = config.nativeThreads;
			if (config.nativeContextSize !== undefined)
				this.core.nativeContextSize = config.nativeContextSize;
			// Phase 0 transport config
			if (config.transport) this.core.transport = config.transport;
			if (config.httpBasePort !== undefined)
				this.core.httpBasePort = config.httpBasePort;
			if (config.httpMaxPortAttempts !== undefined)
				this.core.httpMaxPortAttempts = config.httpMaxPortAttempts;
			if (config.corsOrigin !== undefined)
				this.core.corsOrigin = config.corsOrigin;
		}

		this.mockUrl = this.core.mockUrl;
		this.modelId =
			this.core.backend === "transformers"
				? this.core.transformersModelId
				: this.core.backend === "native"
					? this.core.nativeModelPath
					: this.core.modelId;
		this.backend = this.core.backend;
	}

	/**
	 * Initializes the AI engine.
	 */
	async initialize(): Promise<void> {
		await this.core.initialize((progress) => {
			this.progressText = progress.text;
			this.isReady = this.core.isReady;
			this.notifyListeners();
		});
		this.isReady = this.core.isReady;
		this.notifyListeners();
	}

	/**
	 * Unloads the AI engine and worker.
	 */
	async unload(): Promise<void> {
		await this.core.unload();
		this.isReady = this.core.isReady;
		this.progressText = "";
		this.notifyListeners();
	}

	/**
	 * Perform a direct chat completion (bypasses MSW, calls backend directly).
	 * Useful for programmatic usage without going through the fetch mock.
	 */
	async chatCompletion(requestBody: any): Promise<any> {
		return this.core.chatCompletion(requestBody);
	}

	/**
	 * Run the pipeline directly (Transformers.js backend only).
	 * Use for non-text tasks: text-to-image, ASR, text-to-speech, etc.
	 * @param inputs - Input data appropriate for the pipeline task
	 * @param options - Pipeline-specific options
	 */
	async runPipeline(inputs: any, options?: Record<string, any>): Promise<any> {
		return this.core.runPipeline(inputs, options);
	}

	/**
	 * Get the underlying engine/pipeline instance directly.
	 * - For WebLLM: returns the MLCEngine
	 * - For Transformers.js: returns the pipeline
	 */
	getEngine(): any {
		return this.core.getEngine();
	}

	/** Base URL to point any OpenAI SDK at. Undefined when transport="none". */
	getBaseUrl(): string | undefined {
		return this.core.getBaseUrl();
	}

	/** Bound HTTP port (HTTP transport only). */
	getPort(): number | undefined {
		return this.core.getPort();
	}

	/** Resolved transport kind after initialize(). */
	getActiveTransport(): "msw" | "http" | "none" {
		return this.core.getActiveTransport();
	}

	/**
	 * Subscribes to state changes.
	 * @param listener - Callback function receiving the current state.
	 * @returns A function to unsubscribe.
	 */
	subscribe(listener: VanillaListener): () => void {
		this.listeners.add(listener);
		// Send initial state immediately
		listener(this.getState());
		return () => {
			this.listeners.delete(listener);
		};
	}

	private notifyListeners(): void {
		const state = this.getState();
		this.listeners.forEach((listener) => listener(state));
	}

	/**
	 * Returns the current state.
	 */
	getState(): VanillaState {
		return {
			isReady: this.isReady,
			progress: this.progressText,
			mockUrl: this.mockUrl,
			modelId: this.modelId,
			backend: this.backend,
		};
	}
}

// Attach to global window object for browser `<script>` usage
if (typeof window !== "undefined") {
	(window as any).VanillaDVAI = VanillaDVAI;
}

export default VanillaDVAI;
