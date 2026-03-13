# DvAI-Edge

**DvAI-Edge** is a high-performance, local-first AI orchestration layer that allows you to run robust LLM agents (via WebLLM and LangChain) directly in the browser while maintaining a standard OpenAI-compatible API interface using MSW (Mock Service Worker).

Developed by **Deep Voice Ai Limited**, this library enables privacy-focused, zero-latency AI interactions that work offline and across desktop/mobile environments (including Capacitor).

---

## 🚀 Key Features

- **Local-First**: Runs LLMs entirely in the browser using WebGPU/WebAssembly.
- **OpenAI Compatible**: Exposes a `mockUrl` that behaves exactly like OpenAI's API.
- **Zero Configuration**: No proxy servers or backend needed for the AI engine.
- **Multi-Framework**: First-class support for React, Vanilla JS, and standard node-compatible libraries (LangChain).

---

## 📦 Installation

### React
```bash
pnpm install dvai-edge-react dvai-edge-core
```

### Vanilla JS / CDN
For non-framework projects, you can include the library directly from GitHub via jsDelivr:

```html
<script src="https://cdn.jsdelivr.net/gh/westenets/dvai-edge@main/packages/dvai-edge-vanilla/src/index.js" type="module"></script>
<script type="module">
  import { VanillaDvAI } from 'https://cdn.jsdelivr.net/gh/westenets/dvai-edge@main/packages/dvai-edge-vanilla/src/index.js';
  
  const ai = new VanillaDvAI();
  await ai.initialize();
  
  console.log("Mock API is at:", ai.mockUrl);
</script>
```

---

## 🛠️ Usage Examples

### 1. React Integration
The `dvai-edge-react` package provides a context provider and hooks for seamless integration.

```jsx
import { DvAIProvider, useDvAI } from 'dvai-edge-react';

function App() {
  return (
    <DvAIProvider config={{ 
      modelId: "Llama-3-8B-Instruct-v0.1-q4f16_1-MLC",
      licenseKey: "dvai-your-key-here" // Required for production domains
    }}>
      <ChatComponent />
    </DvAIProvider>
  );
}

function ChatComponent() {
  const { isReady, progressText, mockUrl } = useDvAI();

  if (!isReady) return <div>Loading Engine: {progressText}</div>;

  return <div>Local AI is live at {mockUrl}</div>;
}
```

### 2. LangChain (Core)
Use `dvai-edge-core` to intercept requests from standard AI libraries.

```javascript
import { ChatOpenAI } from "@langchain/openai";
import { DvAI } from "dvai-edge-core";

const core = new DvAI({
  licenseKey: "dvai-your-key-here"
});
await core.initialize();

const chat = new ChatOpenAI({
  configuration: { baseURL: core.mockUrl }, // Intercepted locally!
  modelName: core.modelId,
  apiKey: "not-needed",
});

const res = await chat.invoke("Hello locally!");
```

### 3. Capacitor / Mobile
DvAI-Edge is fully compatible with Capacitor. To ensure MSW intercepts requests correctly on Android/iOS:

1. **Service Worker Placement**: Ensure `mockServiceWorker.js` is in your `public` folder and copied to the `webDir` (usually `www` or `dist`).
2. **Initialization**: Initialize the engine as usual. MSW automatically handles the `capacitor://` or `http://localhost` origins used by Capacitor.

---

## 🔑 License Activation

DvAI-Edge is free for development on `localhost` and `127.0.0.1`. For production domains:
1. Purchase a key from [deepvoiceai.co](https://deepvoiceai.co).
2. Pass the key in the `licenseKey` configuration property.
3. The engine will throw an error if a valid key is not provided on a production domain.

---

## 📜 Licensing

This project is licensed under a **Dual License** model:

1. **Development & Personal Use**: Free to use for development, testing, and personal projects. See `LICENSE` for details.
2. **Commercial Use**: Requires a paid commercial license from **Deep Voice Ai Limited**.

### How to get a Commercial License
To use DvAI-Edge in a production environment or for revenue-generating activities:
1. Visit [Deep Voice Ai Licensing](https://deepvoiceai.co/licensing) (Coming Soon).
2. Contact `info@deepvoiceai.co` for enterprise pricing.
3. Once paid, you will receive a license certificate for your organization.

---

## 🤝 Contribution Guidelines

We welcome contributions! Please follow these steps:
1. Fork the repository `westenets/dvai-edge`.
2. Create a feature branch (`git checkout -b feat/my-feature`).
3. Ensure all tests pass (`npm test`).
4. Submit a Pull Request with a detailed description of changes.

---

© 2026 Deep Voice Ai Limited. All rights reserved.