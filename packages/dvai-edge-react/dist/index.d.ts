import React, { ReactNode } from 'react';
import { InitProgressReport, DvAIConfig } from 'dvai-edge-core';

interface DvAIProviderProps {
    children: ReactNode;
    config?: DvAIConfig;
}
interface DvAIContextValue {
    isReady: boolean;
    progress: InitProgressReport;
    error: Error | null;
    mockUrl: string;
    modelId: string;
    engine: any;
    init: () => Promise<boolean>;
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
