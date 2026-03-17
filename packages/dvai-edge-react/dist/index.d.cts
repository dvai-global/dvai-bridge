import React, { ReactNode } from 'react';
import { BackendType, DvAIConfig } from '@dvai-edge/core';
export { BackendType, DvAIConfig } from '@dvai-edge/core';

interface DvAIProviderProps {
    children: ReactNode;
    config?: DvAIConfig;
}
interface DvAIContextValue {
    /** Whether the AI engine is ready to accept requests. */
    isReady: boolean;
    /** Current initialization progress. */
    progress: {
        text: string;
        progress: number;
        timeElapsed: number;
    };
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
}
/**
 * DvAIProvider: React Context Provider for DvAI-Edge.
 * Manages the initialization state and progress of the local AI engine.
 */
declare const DvAIProvider: React.FC<DvAIProviderProps>;
/**
 * useDvAI Hook: Accesses the DvAI context.
 * Must be used within a DvAIProvider.
 */
declare const useDvAI: () => DvAIContextValue;

export { type DvAIContextValue, DvAIProvider, type DvAIProviderProps, useDvAI };
