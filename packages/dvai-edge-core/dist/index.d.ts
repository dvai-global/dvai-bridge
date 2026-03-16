import { InitProgressReport, MLCEngine } from '@mlc-ai/web-llm';
export { InitProgressReport } from '@mlc-ai/web-llm';
import { SetupWorker } from 'msw/browser';

interface DvAIConfig {
    modelId?: string;
    mockUrl?: string;
    serviceWorkerUrl?: string;
    licenseKey?: string;
    autoInit?: boolean;
}
/**
 * DvAI: Local AI Orchestration
 * Orchestrates WebLLM for local execution and MSW for intercepting API calls.
 */
declare class DvAI {
    modelId: string;
    mockUrl: string;
    serviceWorkerUrl: string;
    licenseKey?: string;
    private validator;
    private engine;
    private worker;
    isReady: boolean;
    constructor(config?: DvAIConfig);
    /**
     * Initializes the MSW Service Worker and the WebLLM engine.
     * @param onProgress - Callback for model download progress (e.g. { text: "Loading..." })
     */
    initialize(onProgress?: (info: InitProgressReport) => void): Promise<boolean>;
    /**
     * Gets the WebLLM engine instance directly if needed.
     */
    getEngine(): MLCEngine | null;
    /**
     * Gets the MSW worker instance directly if needed.
     */
    getWorker(): SetupWorker | null;
    /**
     * Unloads the LLM engine and stops the MSW worker to free up resources.
     */
    unload(): Promise<void>;
}
declare const dvai: DvAI;

export { DvAI, type DvAIConfig, dvai };
