# Getting Started

Follow these steps to integrate DvAI-Edge into your project.

## Installation

Install the core package along with any backends you plan to use.

```bash
# Core package
pnpm add @dvai-edge/core

# WebLLM (for browsers)
pnpm add @mlc-ai/web-llm

# Transformers.js (for high compatibility)
pnpm add @huggingface/transformers

# Native LLM (for Capacitor/Mobile)
pnpm add llama-cpp-capacitor
```

### Framework Wrappers

```bash
# For React projects
pnpm add @dvai-edge/react

# For Vanilla JS / Non-framework projects
pnpm add @dvai-edge/vanilla
```

## Initialization

DvAI-Edge requires certain worker files to be available in your application's `public` folder. You can initialize these automatically:

```bash
npx dvai-edge init ./public
```

This command copies:
- `mockServiceWorker.js`: For OpenAI-compatible API interception.
- `dvai-webllm.worker.js`: For WebLLM offloading.
- `dvai-transformers.worker.js`: For Transformers.js offloading.

## Basic Usage

### Using with React

Wrap your app with `DvAIProvider` to initialize the orchestration layer.

```tsx
import { DvAIProvider, useDvAI } from '@dvai-edge/react';

function App() {
  return (
    <DvAIProvider config={{ 
      backend: 'auto', // Automatically selects Native on Mobile, WebLLM on Web
      nativeModelPath: 'public/models/mistral-7b-v0.1.Q4_K_M.gguf',
      modelId: 'gemma-2-2b-it-q4f16_1-MLC'
    }}>
      <MyChat />
    </DvAIProvider>
  );
}

function MyChat() {
  const { isReady, mockUrl } = useDvAI();
  
  // Use mockUrl with any OpenAI-compatible SDK (LangChain, Vercel AI SDK, etc.)
  return <div>AI is {isReady ? 'Ready' : 'Loading...'}</div>;
}
```

### Using with Vanilla JS

```javascript
import { VanillaDvAI } from '@dvai-edge/vanilla';

const ai = new VanillaDvAI({
  backend: 'webllm',
  modelId: 'gemma-2-2b-it-q4f16_1-MLC'
});

await ai.initialize();
console.log('API intercepted at:', ai.mockUrl);
```
