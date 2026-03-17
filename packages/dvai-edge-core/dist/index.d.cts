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

type BackendType = "webllm" | "transformers";
type DeviceType = "webgpu" | "cpu" | "auto";

interface DvAIConfig {
    /** The model ID for web-llm backend. Default: "Qwen2.5-1.5B-Instruct-q4f16_1-MLC" */
    modelId?: string;
    /** The backend engine to use. Default: "webllm" */
    backend?: BackendType;
    /** HuggingFace model ID for Transformers.js backend. Default: "Xenova/Qwen2.5-0.5B-Instruct" */
    transformersModelId?: string;
    /** Pipeline task for Transformers.js (e.g. "text-generation", "text-to-image", "automatic-speech-recognition"). Default: "text-generation" */
    pipelineTask?: string;
    /** Device for Transformers.js - "webgpu", "cpu", or "auto" (detect). Default: "auto" */
    device?: DeviceType;
    /** Generation timeout in ms. Default: 60000 (60s) */
    generationTimeout?: number;
    /** Maximum consecutive blank chunks before aborting stream. Default: 20 */
    maxBlankChunks?: number;
    /** Mock URL for MSW interception. Default: "https://api.openai.local/v1/chat/completions" */
    mockUrl?: string;
    /** Path to the MSW service worker script. Default: "/mockServiceWorker.js" */
    serviceWorkerUrl?: string;
    /** URL to the WebLLM worker script (for offloading inference). Default: "/dvai-webllm.worker.js" */
    webllmWorkerUrl?: string;
    /** URL to the Transformers.js worker script (for offloading inference). Default: "/dvai-transformers.worker.js" */
    transformersWorkerUrl?: string;
    /** License key for production use. */
    licenseKey?: string;
    /** Auto-initialize on creation (React/Vanilla). Default: true */
    autoInit?: boolean;
}
/**
 * DvAI: Local AI Orchestration
 * Orchestrates WebLLM or Transformers.js for local execution
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
    webllmWorkerUrl: string;
    transformersWorkerUrl: string;
    private validator;
    private backendInstance;
    private worker;
    isReady: boolean;
    constructor(config?: DvAIConfig);
    /**
     * Returns the active backend type.
     */
    getActiveBackend(): BackendType;
    /**
     * Initializes the MSW Service Worker and the selected backend engine.
     * @param onProgress - Callback for model download progress
     */
    initialize(onProgress?: (info: any) => void): Promise<boolean>;
    /**
     * Lazy-imports and initializes the selected backend.
     */
    private initializeBackend;
    /**
     * Gets the underlying engine instance directly.
     * - For WebLLM: returns the MLCEngine
     * - For Transformers.js: returns the pipeline
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

export { type BackendType, type DeviceType, DvAI, type DvAIConfig, type PipelineTask, type TransformersProgressInfo, detectWebGPU, dvai };
