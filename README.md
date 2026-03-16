# DvAI-Edge

**DvAI-Edge** is a high-performance, local-first AI orchestration layer that allows you to run robust LLM agents (via WebLLM and LangChain) directly in the browser while maintaining a standard OpenAI-compatible API interface using MSW (Mock Service Worker).

Developed by **Deep Voice Ai Limited**, this library enables privacy-focused, zero-latency AI interactions that work offline and across desktop/mobile environments (including Capacitor).

---

## 🚀 Key Features

- **Local-First**: Runs LLMs entirely in the browser using WebGPU/WebAssembly.
- **OpenAI Compatible**: Exposes a `mockUrl` that behaves exactly like OpenAI's API.
- **Zero Configuration**: No proxy servers or backend needed for the AI engine.
- **TypeScript First**: Full IntelliSense and type safety across all packages.
- **Monorepo Design**: Purpose-built packages for React and Vanilla JS.

---

## 📦 Packages

The monorepo consists of three main packages:
- **`dvai-edge-core`**: Core logic and orchestration.
- **`dvai-edge-react`**: React components and hooks.
- **`dvai-edge-vanilla`**: Wrapper for non-framework environments.

---

### 1. Installation
Depending on your workflow, you can add this repository as a submodule or install via npm (once published).

#### As a Git Submodule
```bash
git submodule add https://github.com/westenets/dvai-edge.git
cd dvai-edge
pnpm install
pnpm build
```

#### Via npm (Coming Soon)
```bash
npm install @dvai/dvai-edge-core
```

### 2. Initialize Service Worker
DvAI-Edge requires a service worker to intercept OpenAI API calls. Use the built-in CLI to initialize it:
```bash
# If using as submodule, run from the submodule root or via npx
npx dvai-edge init [public-dir]
```
*Note: `public-dir` defaults to `public` (Standard for Next.js/Vite).*

---

## 💻 Usage

### React Integration
```tsx
import { DvAIProvider, useDvAI } from 'dvai-edge-react';

function App() {
  return (
    <DvAIProvider config={{ 
      modelId: "Qwen2.5-1.5B-Instruct-q4f16_1-MLC",
      licenseKey: "dvai-your-key-here" 
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

### Vanilla JS / CDN
```html
<!-- Direct CDN usage -->
<script src="https://cdn.jsdelivr.net/npm/dvai-edge-vanilla/dist/index.global.js"></script>
<script>
  const ai = new VanillaDvAI();
  ai.initialize().then(() => {
    console.log("Mock API is active!");
  });
</script>
```

---

## 🔋 Resource Management (Mobile & Laptop)

To preserve battery life and free up system resources (RAM/VRAM/CPU) when the AI is not needed, you can programmatically unload the engine and stop the service worker.

### React
```tsx
const { unload, init } = useDvAI();

// Unload when done
await unload();

// Re-initialize later
await init();
```

### Vanilla JS
```javascript
const ai = new VanillaDvAI();

// Unload resources
await ai.unload();

// Re-initialize
await ai.initialize();
```

---

## 🔑 License Activation

DvAI-Edge is free for development on `localhost` and `127.0.0.1`. In production, the `LicenseValidator` checks for valid signed keys.

1. **Mobile Production**: Detects native `DEBUG` flags in Capacitor and Cordova to ensure license requirements are met even on `localhost`.
2. **Setup**: Pass your key in the `licenseKey` property.
3. **Get a Key**: Contact `info@deepvoiceai.co` for commercial licensing.

---

## 📜 Licensing

This project is licensed under a **Dual License** model:
1. **Development & Personal Use**: Free to use for development and testing.
2. **Commercial Use**: Requires a paid license from **Deep Voice Ai Limited**.

---

## 🤝 Contributing

We use `pnpm` for monorepo management.
1. Clone the repo: `git clone https://github.com/westenets/dvai-edge.git`
2. Install dependencies: `pnpm install`
3. Build all packages: `pnpm build`
4. Create a feature branch and submit a PR!

---

© 2026 Deep Voice Ai Limited. All rights reserved.