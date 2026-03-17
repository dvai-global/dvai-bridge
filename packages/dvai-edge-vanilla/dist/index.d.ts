import { DvAIConfig, BackendType } from '@dvai-edge/core';
export { BackendType, DvAIConfig } from '@dvai-edge/core';

interface VanillaState {
    isReady: boolean;
    progress: string;
    mockUrl: string;
    modelId: string;
    backend: BackendType;
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
    private backend;
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
     * Returns the current state.
     */
    getState(): VanillaState;
}

export { VanillaDvAI, type VanillaListener, type VanillaState, VanillaDvAI as default };
