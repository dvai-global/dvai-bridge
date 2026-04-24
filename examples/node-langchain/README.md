# node-langchain

Runs `dvai-bridge` in plain Node with LangChain's `ChatOpenAI`,
talking to a local Transformers.js model.

## Run

```bash
pnpm --filter node-langchain start
```

The first run downloads the model. Subsequent runs use the HuggingFace cache.
