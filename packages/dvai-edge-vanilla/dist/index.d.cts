interface DvAIConfig {
    modelId?: string;
    mockUrl?: string;
    serviceWorkerUrl?: string;
    licenseKey?: string;
    autoInit?: boolean;
}

interface VanillaState {
    isReady: boolean;
    progress: string;
    mockUrl: string;
    modelId: string;
}
type VanillaListener = (state: VanillaState) => void;
/**
 * VanillaDvAI: A simple wrapper for dvai-edge-core to be used in vanilla JS applications.
 */
declare class VanillaDvAI {
    private core;
    private isReady;
    private progressText;
    private mockUrl;
    private modelId;
    private listeners;
    constructor(config?: DvAIConfig);
    /**
     * Initializes the AI engine.
     */
    initialize(): Promise<void>;
    /**
     * Unloads the AI engine and worker.
     */
    unload(): Promise<void>;
    /**
     * Subscribes to state changes.
     * @param listener - Callback function receiving the current state.
     * @returns A function to unsubscribe.
     */
    subscribe(listener: VanillaListener): () => void;
    private notifyListeners;
    /**
     * returns the current state.
     */
    getState(): VanillaState;
}

export { VanillaDvAI, type VanillaListener, type VanillaState, VanillaDvAI as default };
