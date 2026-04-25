import React, {
	createContext,
	useContext,
	useEffect,
	useState,
	useRef,
	useCallback,
	ReactNode,
} from "react";
import { dvai, type DVAIConfig, type BackendType } from "@dvai-bridge/core";

export type { DVAIConfig, BackendType } from "@dvai-bridge/core";

export interface DVAIProviderProps {
	children: ReactNode;
	config?: DVAIConfig;
}

export interface DVAIContextValue {
	/** Whether the AI engine is ready to accept requests. */
	isReady: boolean;
	/** Current initialization progress. */
	progress: { text: string; progress: number; timeElapsed: number };
	/** Any error from initialization. */
	error: Error | null;
	/** The mock URL for OpenAI-compatible API calls. */
	mockUrl: string;
	/** The model ID for the active backend. */
	modelId: string;
	/** The active backend type ("webllm" or "transformers"). */
	backend: BackendType;
	/** The underlying engine instance (MLCEngine or transformers pipeline). */
	engine: any;
	/** Initialize the AI engine manually. */
	init: () => Promise<boolean>;
	/** Unload the AI engine and free resources. */
	unload: () => Promise<void>;
	/**
	 * Perform a direct chat completion (bypasses MSW, calls backend directly).
	 * Useful for programmatic usage without going through the fetch mock.
	 */
	chatCompletion: (requestBody: any) => Promise<any>;
	/**
	 * Run the pipeline directly (Transformers.js backend only).
	 * Use for non-text tasks: text-to-image, ASR, text-to-speech, etc.
	 * @param inputs - Input data appropriate for the pipeline task
	 * @param options - Pipeline-specific options
	 */
	runPipeline: (inputs: any, options?: Record<string, any>) => Promise<any>;
	/** Get the underlying engine/pipeline instance directly. */
	getEngine: () => any;
	/** Base URL to point any OpenAI SDK at. Undefined when transport="none". */
	baseUrl: string | undefined;
	/** Bound HTTP port (HTTP transport only). Undefined for MSW/none. */
	port: number | undefined;
	/** Resolved transport kind after initialize(). */
	activeTransport: "msw" | "http" | "none" | "capacitor";
}

const DVAIContext = createContext<DVAIContextValue | null>(null);

/**
 * DVAIProvider: React Context Provider for DVAI-Bridge.
 * Manages the initialization state and progress of the local AI engine.
 */
export const DVAIProvider: React.FC<DVAIProviderProps> = ({
	children,
	config = {},
}) => {
	const [isReady, setIsReady] = useState(false);
	const [progress, setProgress] = useState<{
		text: string;
		progress: number;
		timeElapsed: number;
	}>({
		text: "Initializing...",
		progress: 0,
		timeElapsed: 0,
	});
	const [error, setError] = useState<Error | null>(null);
	const hasInitialized = useRef(false);

	const init = useCallback(async (): Promise<boolean> => {
		if (hasInitialized.current) return true;
		hasInitialized.current = true;

		// Apply custom config before initialization
		if (config.modelId) dvai.modelId = config.modelId;
		if (config.mockUrl) dvai.mockUrl = config.mockUrl;
		if (config.serviceWorkerUrl)
			dvai.serviceWorkerUrl = config.serviceWorkerUrl;
		if (config.backend) dvai.backend = config.backend;
		if (config.transformersModelId)
			dvai.transformersModelId = config.transformersModelId;
		if (config.pipelineTask) dvai.pipelineTask = config.pipelineTask;
		if (config.device) dvai.device = config.device;
		if (config.generationTimeout !== undefined)
			dvai.generationTimeout = config.generationTimeout;
		if (config.maxBlankChunks !== undefined)
			dvai.maxBlankChunks = config.maxBlankChunks;
		if (config.maxRetries !== undefined) dvai.maxRetries = config.maxRetries;
		if (config.webllmWorkerUrl) dvai.webllmWorkerUrl = config.webllmWorkerUrl;
		if (config.transformersWorkerUrl)
			dvai.transformersWorkerUrl = config.transformersWorkerUrl;
		// Native backend config
		if (config.nativeModelPath) dvai.nativeModelPath = config.nativeModelPath;
		if (config.nativeGpuLayers !== undefined)
			dvai.nativeGpuLayers = config.nativeGpuLayers;
		if (config.nativeThreads !== undefined)
			dvai.nativeThreads = config.nativeThreads;
		if (config.nativeContextSize !== undefined)
			dvai.nativeContextSize = config.nativeContextSize;
		// Phase 0 transport config
		if (config.transport) dvai.transport = config.transport;
		if (config.httpBasePort !== undefined)
			dvai.httpBasePort = config.httpBasePort;
		if (config.httpMaxPortAttempts !== undefined)
			dvai.httpMaxPortAttempts = config.httpMaxPortAttempts;
		if (config.corsOrigin !== undefined) dvai.corsOrigin = config.corsOrigin;

		try {
			await dvai.initialize((info) => {
				setProgress(info);
			});
			setIsReady(true);
			return true;
		} catch (err: any) {
			setError(err instanceof Error ? err : new Error(String(err)));
			return false;
		}
	}, [config]);

	const unload = useCallback(async () => {
		await dvai.unload();
		setIsReady(false);
		hasInitialized.current = false;
		setProgress({ text: "Unloaded", progress: 0, timeElapsed: 0 });
	}, []);

	useEffect(() => {
		if (config.autoInit !== false) {
			init();
		}
	}, [config, init]);

	const chatCompletion = useCallback(async (requestBody: any): Promise<any> => {
		return dvai.chatCompletion(requestBody);
	}, []);

	const runPipeline = useCallback(
		async (inputs: any, options?: Record<string, any>): Promise<any> => {
			return dvai.runPipeline(inputs, options);
		},
		[],
	);

	const getEngine = useCallback(() => dvai.getEngine(), []);

	const value: DVAIContextValue = {
		isReady,
		progress,
		error,
		mockUrl: dvai.mockUrl,
		modelId:
			dvai.backend === "transformers" ? dvai.transformersModelId : dvai.modelId,
		backend: dvai.backend,
		engine: dvai.getEngine(),
		init,
		unload,
		chatCompletion,
		runPipeline,
		getEngine,
		baseUrl: dvai.baseUrl,
		port: dvai.port,
		activeTransport: dvai.getActiveTransport(),
	};

	return <DVAIContext.Provider value={value}>{children}</DVAIContext.Provider>;
};

/**
 * useDVAI Hook: Accesses the DVAI context.
 * Must be used within a DVAIProvider.
 */
export const useDVAI = (): DVAIContextValue => {
	const context = useContext(DVAIContext);
	if (!context) {
		throw new Error("useDVAI must be used within a DVAIProvider");
	}
	return context;
};
