import React, { createContext, useContext, useEffect, useState, useRef, useCallback, ReactNode } from "react";
import { dvai, type DvAIConfig, type BackendType } from "@dvai-edge/core";

export type { DvAIConfig, BackendType } from "@dvai-edge/core";

export interface DvAIProviderProps {
  children: ReactNode;
  config?: DvAIConfig;
}

export interface DvAIContextValue {
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
}

const DvAIContext = createContext<DvAIContextValue | null>(null);

/**
 * DvAIProvider: React Context Provider for DvAI-Edge.
 * Manages the initialization state and progress of the local AI engine.
 */
export const DvAIProvider: React.FC<DvAIProviderProps> = ({ children, config = {} }) => {
  const [isReady, setIsReady] = useState(false);
  const [progress, setProgress] = useState<{ text: string; progress: number; timeElapsed: number }>({
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
    if (config.serviceWorkerUrl) dvai.serviceWorkerUrl = config.serviceWorkerUrl;
    if (config.backend) dvai.backend = config.backend;
    if (config.transformersModelId) dvai.transformersModelId = config.transformersModelId;
    if (config.pipelineTask) dvai.pipelineTask = config.pipelineTask;
    if (config.device) dvai.device = config.device;
    if (config.generationTimeout !== undefined) dvai.generationTimeout = config.generationTimeout;
    if (config.maxBlankChunks !== undefined) dvai.maxBlankChunks = config.maxBlankChunks;
    if (config.webllmWorkerUrl) dvai.webllmWorkerUrl = config.webllmWorkerUrl;
    if (config.transformersWorkerUrl) dvai.transformersWorkerUrl = config.transformersWorkerUrl;

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

  const value: DvAIContextValue = {
    isReady,
    progress,
    error,
    mockUrl: dvai.mockUrl,
    modelId: dvai.backend === "transformers" ? dvai.transformersModelId : dvai.modelId,
    backend: dvai.backend,
    engine: dvai.getEngine(),
    init,
    unload,
  };

  return (
    <DvAIContext.Provider value={value}>
      {children}
    </DvAIContext.Provider>
  );
};

/**
 * useDvAI Hook: Accesses the DvAI context.
 * Must be used within a DvAIProvider.
 */
export const useDvAI = (): DvAIContextValue => {
  const context = useContext(DvAIContext);
  if (!context) {
    throw new Error("useDvAI must be used within a DvAIProvider");
  }
  return context;
};
