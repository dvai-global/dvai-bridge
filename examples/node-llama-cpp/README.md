# node-llama-cpp

Node example that runs `dvai-bridge` over the **native** backend
(node-llama-cpp + a GGUF file on disk), exposing the same
OpenAI-compatible HTTP server the Transformers.js backend uses.
LangChain's `ChatOpenAI` streams tokens through the bridge — no
DVAI-specific client code.

## Run

```bash
# One-time, from repo root:
pnpm install --ignore-scripts

# Then, from this directory or via the workspace filter:
pnpm --filter node-llama-cpp start
```

The first run downloads
[`bartowski/Llama-3.2-1B-Instruct-GGUF`](https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF)
(Q4\_K\_M, ~800 MB) into `models/Llama-3.2-1B-Instruct-Q4_K_M.gguf`.
`models/` is gitignored. Subsequent runs reuse the cached file.

You can pre-download the model out-of-band:

```bash
pnpm --filter node-llama-cpp download-model
```

## What it shows

- `backend: "native"` selects node-llama-cpp under the hood. The HTTP
  transport binds 127.0.0.1 on the first free port from 38883; LangChain
  hits that URL via `configuration.baseURL`.
- `LlamaChatSession.prompt({ onTextChunk })` provides true token-level
  streaming, re-shaped by dvai-bridge into OpenAI SSE chunks.
- The example's only DVAI-specific lines are the `new DVAI({...})` and
  `dvai.baseUrl` reads — everything else is stock LangChain.

## Configuration knobs

```js
new DVAI({
  backend: "native",
  nativeModelPath: "/abs/path/to/your.gguf",
  nativeContextSize: 4096,    // default 2048
  nativeGpuLayers: 32,        // default 99 (max offload)
  nativeThreads: 8,           // default: node-llama-cpp's auto
  generationTimeout: 120_000, // ms
});
```

## Smoke test

```bash
bash smoke.sh
```

`smoke.sh` runs `index.js` end-to-end, verifies that the native backend
returns a non-empty completion to `"Say hello"` within 60 s, and exits
0 on success. If the GGUF is not yet cached, the smoke test downloads
it first (this can add 1-3 minutes on a first run).

## Swap the model

Edit `scripts/download-model.js` and `index.js` to point at any
GGUF-compatible model file. node-llama-cpp picks up the chat template
automatically from the GGUF metadata.
