import React, { createContext, useContext, useEffect, useState, useRef } from "react";
import { dvai } from "dvai-edge-core";

const DvAIContext = createContext(null);

export const DvAIProvider = ({ children, config = {} }) => {
  const [isReady, setIsReady] = useState(false);
  const [progress, setProgress] = useState({ text: "Initializing...", progress: 0 });
  const [error, setError] = useState(null);
  const hasInitialized = useRef(false);

  useEffect(() => {
    if (hasInitialized.current) return;
    hasInitialized.current = true;

    // Apply custom config before initialization
    if (config.modelId) dvai.modelId = config.modelId;
    if (config.mockUrl) dvai.mockUrl = config.mockUrl;
    if (config.serviceWorkerUrl) dvai.serviceWorkerUrl = config.serviceWorkerUrl;

    const initDvAI = async () => {
      try {
        await dvai.initialize((info) => {
          setProgress(info);
        });
        setIsReady(true);
      } catch (err) {
        setError(err);
      }
    };

    initDvAI();
  }, [config]);

  const value = {
    isReady,
    progress,
    error,
    mockUrl: dvai.mockUrl,
    modelId: dvai.modelId,
    engine: dvai.getEngine(),
  };

  return (
    <DvAIContext.Provider value={value}>
      {children}
    </DvAIContext.Provider>
  );
};

export const useDvAI = () => {
  const context = useContext(DvAIContext);
  if (!context) {
    throw new Error("useDvAI must be used within a DvAIProvider");
  }
  return context;
};
