# Examples

Runnable examples for `@dvai-bridge/core`. Each one is a standalone
workspace package — no extra install step beyond `pnpm install` at the repo root.

| Example | Platform | Backend | Transport | What it shows |
|---|---|---|---|---|
| `web-react` | Browser | WebLLM / Transformers.js | MSW | React + Vite + `@dvai-bridge/react` |
| `node-langchain` | Node | Transformers.js | HTTP | LangChain + OpenAI SDK against local loopback |

## Run

```bash
pnpm install
pnpm --filter <example-name> start   # or `dev`, `build` — check the example's package.json
```
