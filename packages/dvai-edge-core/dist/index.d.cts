import { SetupWorker } from 'msw/browser';
export { InitProgressReport } from '@mlc-ai/web-llm';

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
type PipelineTask = string;
interface TransformersProgressInfo {
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
declare function detectWebGPU(): Promise<boolean>;

/**
 * NativeBackend: Wraps llama-cpp-capacitor for native on-device inference.
 * - Uses llama.cpp via Capacitor plugin for Metal (iOS) / Vulkan (Android)
 * - Provides OpenAI-compatible chat completion response format
 * - Supports streaming via token callbacks
 * - Falls back gracefully when not running in Capacitor
 */
interface NativeBackendConfig {
    modelPath: string;
    contextSize?: number;
    threads?: number;
    gpuLayers?: number;
    generationTimeout?: number;
}
declare class NativeBackend {
    private context;
    private modelPath;
    private contextSize;
    private threads;
    private gpuLayers;
    private generationTimeout;
    constructor(config: NativeBackendConfig);
    /**
     * Detect whether we're in a Capacitor Native environment.
     */
    static isAvailable(): boolean;
    initialize(onProgress?: (info: any) => void): Promise<void>;
    /**
     * Non-streaming chat completion.
     * Accepts OpenAI-format request body {messages, max_tokens, temperature, ...}
     * Returns OpenAI-format response.
     */
    chatCompletion(requestBody: any): Promise<any>;
    /**
     * Streaming chat completion.
     * Returns a ReadableStream of SSE-formatted data (OpenAI streaming format).
     */
    createStreamingResponse(requestBody: any): ReadableStream<Uint8Array>;
    /**
     * Get the native LlamaContext instance.
     */
    getEngine(): any;
    isWorkerBased(): boolean;
    /**
     * Unloads the model and frees native memory.
     */
    unload(): Promise<void>;
    /** Wraps a promise with a timeout. */
    private withTimeout;
}

type BackendType = "webllm" | "transformers" | "native" | "auto";
type DeviceType = "webgpu" | "cpu" | "auto";

interface DvAIConfig {
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
declare class DvAI {
    modelId: string;
    mockUrl: string;
    serviceWorkerUrl: string;
    licenseKey?: string;
    backend: BackendType;
    transformersModelId: string;
    pipelineTask: string;
    device: DeviceType;
    generationTimeout: number;
    maxBlankChunks: number;
    maxRetries: number;
    webllmWorkerUrl: string;
    transformersWorkerUrl: string;
    nativeModelPath: string;
    nativeGpuLayers: number;
    nativeThreads: number;
    nativeContextSize: number;
    private validator;
    private backendInstance;
    private worker;
    isReady: boolean;
    /** Tracks how many consecutive recovery attempts have been made. */
    private recoveryAttempts;
    /** The resolved backend type (after "auto" resolution). */
    private resolvedBackend;
    constructor(config?: DvAIConfig);
    /**
     * Returns the active backend type (resolved from "auto" if applicable).
     */
    getActiveBackend(): "webllm" | "transformers" | "native";
    /**
     * Resolves the "auto" backend to a concrete type based on environment.
     */
    private resolveBackend;
    /**
     * Initializes the MSW Service Worker and the selected backend engine.
     * @param onProgress - Callback for model download progress
     */
    initialize(onProgress?: (info: any) => void): Promise<boolean>;
    /**
     * Attempts to recover from a fatal WebLLM error by unloading and reloading the backend.
     */
    private attemptRecovery;
    /**
     * Lazy-imports and initializes the selected backend.
     */
    private initializeBackend;
    /**
     * Gets the underlying engine instance directly.
     * - For WebLLM: returns the MLCEngine
     * - For Transformers.js: returns the pipeline
     * - For Native: returns the LlamaContext
     */
    getEngine(): any;
    /**
     * Gets the MSW worker instance directly if needed.
     */
    getWorker(): SetupWorker | null;
    /**
     * Perform a direct chat completion (bypasses MSW, calls backend directly).
     * Useful for programmatic usage without going through the fetch mock.
     */
    chatCompletion(requestBody: any): Promise<any>;
    /**
     * Run the pipeline directly (Transformers.js only).
     * Use this for non-text tasks like text-to-image, ASR, text-to-speech, etc.
     * @param inputs - Input data appropriate for the pipeline task
     * @param options - Pipeline-specific options
     */
    runPipeline(inputs: any, options?: Record<string, any>): Promise<any>;
    /**
     * Unloads the AI engine and stops the MSW worker to free up resources.
     */
    unload(): Promise<void>;
}
declare const dvai: DvAI;

export { type BackendType, type DeviceType, DvAI, type DvAIConfig, NativeBackend, type PipelineTask, type TransformersProgressInfo, detectWebGPU, dvai };
