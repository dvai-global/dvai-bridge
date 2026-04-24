# Phase 0 Transport Abstraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the four OpenAI-compatible handlers from `DVAI.buildMswHandlers` into a transport-agnostic module, add an `http.createServer`-based transport for Node/Electron, and prove equivalence with an integration test. Ship as 1.6.0 with zero breaking changes to the web path.

**Architecture:** Single `initialize()` entry point auto-selects transport at runtime (MSW in browsers, HTTP in Node, "none" in workers). Handlers are pure `(body, ctx) → Response` functions. Transports are thin adapters. All state threading happens via a `HandlerContext` built once per `initialize()`.

**Tech Stack:** TypeScript, Node 20+, pnpm workspaces, vitest (with happy-dom for MSW-side tests), msw, tsup.

**Spec:** [`docs/superpowers/specs/2026-04-24-phase0-transport-abstraction-design.md`](../specs/2026-04-24-phase0-transport-abstraction-design.md)

---

## Phase A — Repository restructure

Do these first. They're non-TDD (moves/config changes) but isolated and reviewable on their own.

### Task 1: Add `files` allowlist to all three packages

**Files:**
- Modify: `packages/dvai-bridge-core/package.json`
- Modify: `packages/dvai-bridge-react/package.json`
- Modify: `packages/dvai-bridge-vanilla/package.json`

- [ ] **Step 1: Add `files` field to `@dvai-bridge/core`**

Insert the `files` field just above `"scripts"` in `packages/dvai-bridge-core/package.json`:

```json
  "files": [
    "dist",
    "bin",
    "README.md",
    "LICENSE"
  ],
```

- [ ] **Step 2: Add `files` field to `@dvai-bridge/react`**

Insert the `files` field just above `"scripts"` in `packages/dvai-bridge-react/package.json`:

```json
  "files": [
    "dist",
    "README.md",
    "LICENSE"
  ],
```

- [ ] **Step 3: Add `files` field to `@dvai-bridge/vanilla`**

Insert the `files` field just above `"scripts"` in `packages/dvai-bridge-vanilla/package.json`:

```json
  "files": [
    "dist",
    "README.md",
    "LICENSE"
  ],
```

- [ ] **Step 4: Verify tarball contents**

Run from each package dir:

```bash
cd packages/dvai-bridge-core && pnpm pack --dry-run
cd ../dvai-bridge-react   && pnpm pack --dry-run
cd ../dvai-bridge-vanilla && pnpm pack --dry-run
```

Expected: only `dist/`, `bin/` (core only), `package.json`, `README.md`, `LICENSE` listed. No `src/`, no `example/`, no `node_modules/`.

- [ ] **Step 5: Commit**

```bash
git add packages/dvai-bridge-core/package.json packages/dvai-bridge-react/package.json packages/dvai-bridge-vanilla/package.json
git commit -m "chore: add files allowlist to all packages"
```

---

### Task 2: Move `test-app` to `examples/web-react`

**Files:**
- Move: `packages/dvai-bridge-core/example/test-app/` → `examples/web-react/`
- Modify: `pnpm-workspace.yaml`
- Modify: `examples/web-react/package.json` (rename)

- [ ] **Step 1: Create `examples/` directory and move test-app**

```bash
mkdir examples
git mv packages/dvai-bridge-core/example/test-app examples/web-react
```

- [ ] **Step 2: Rename the example in its package.json**

Edit `examples/web-react/package.json`, change the `name` field:

```json
{
  "name": "web-react",
  ...
}
```

(Was `"name": "test-app"`.)

- [ ] **Step 3: Update `pnpm-workspace.yaml`**

Replace the entire file with:

```yaml
packages:
  - 'packages/*'
  - 'examples/*'
  - 'docs'

onlyBuiltDependencies:
  - esbuild
  - msw
  - onnxruntime-node
  - protobufjs
  - sharp
```

- [ ] **Step 4: Reinstall workspace**

```bash
pnpm install
```

Expected: success with `web-react` listed as a workspace package and `test-app` no longer listed.

- [ ] **Step 5: Verify the example still builds**

```bash
pnpm --filter web-react build
```

Expected: `vite build` succeeds.

- [ ] **Step 6: Commit**

```bash
git add .
git commit -m "chore: move web example to examples/web-react"
```

---

### Task 3: Promote the langchain example; delete the old standalone .js

**Files:**
- Delete: `packages/dvai-bridge-core/example/langchain-node-example.js`
- Delete: `packages/dvai-bridge-core/example/` (empty afterward)
- Create: `examples/node-langchain/package.json`
- Create: `examples/node-langchain/index.js`
- Create: `examples/node-langchain/README.md`
- Create: `examples/README.md`

- [ ] **Step 1: Create `examples/node-langchain/package.json`**

```json
{
  "name": "node-langchain",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "start": "node index.js"
  },
  "dependencies": {
    "@dvai-bridge/core": "workspace:*",
    "@langchain/core": "^1.1.36",
    "@langchain/openai": "^1.3.1",
    "@huggingface/transformers": "^4.0.1"
  }
}
```

- [ ] **Step 2: Create `examples/node-langchain/index.js`**

```javascript
/**
 * Node + LangChain + dvai-bridge example.
 *
 * dvai-bridge starts a local OpenAI-compatible HTTP server on 127.0.0.1
 * and routes requests to a local Transformers.js model. Point LangChain's
 * ChatOpenAI at `dvai.baseUrl` and everything else stays standard.
 */
import { ChatOpenAI } from "@langchain/openai";
import { HumanMessage, SystemMessage } from "@langchain/core/messages";
import { DVAI } from "@dvai-bridge/core";

async function main() {
  const dvai = new DVAI({
    backend: "transformers",
    transformersModelId: "onnx-community/gemma-3n-E2B-it-ONNX",
  });

  await dvai.initialize((progress) =>
    console.log(`Loading model: ${progress.text ?? ""}`),
  );

  console.log(`[dvai] Local server ready at ${dvai.baseUrl}`);

  const chat = new ChatOpenAI({
    modelName: dvai.getActiveBackend() === "transformers" ? dvai.transformersModelId : dvai.modelId,
    apiKey: "local-bypass-key",
    maxTokens: 256,
    streaming: true,
    configuration: { baseURL: dvai.baseUrl },
  });

  const stream = await chat.stream([
    new SystemMessage("You are a helpful local AI."),
    new HumanMessage("What is the capital of France?"),
  ]);

  for await (const chunk of stream) {
    process.stdout.write(String(chunk.content));
  }
  console.log();

  await dvai.unload();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

- [ ] **Step 3: Create `examples/node-langchain/README.md`**

```markdown
# node-langchain

Runs `dvai-bridge` in plain Node with LangChain's `ChatOpenAI`,
talking to a local Transformers.js model.

## Run

```bash
pnpm --filter node-langchain start
```

The first run downloads the model. Subsequent runs use the HuggingFace cache.
```

- [ ] **Step 4: Create `examples/README.md`**

```markdown
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
```

- [ ] **Step 5: Delete the old example directory**

```bash
git rm -r packages/dvai-bridge-core/example
```

- [ ] **Step 6: Reinstall + verify**

```bash
pnpm install
pnpm -r run build
```

Expected: all packages build, including both examples.

- [ ] **Step 7: Commit**

```bash
git add .
git commit -m "chore: promote langchain example and add examples index"
```

---

## Phase B — Handler extraction (TDD)

Each handler extracted behind a test before the caller is rewired. `buildMswHandlers` stays intact until Task 9.

### Task 4: Create `handlers/context.ts` (types only)

**Files:**
- Create: `packages/dvai-bridge-core/src/handlers/context.ts`

- [ ] **Step 1: Write `context.ts`**

```typescript
/**
 * Duck-typed backend contract consumed by the transport-agnostic handlers.
 * All three existing backends (WebLLMBackend, TransformersBackend, NativeBackend)
 * satisfy this structurally without any backend changes.
 */
export interface BackendInterface {
  chatCompletion(body: any): Promise<any>;
  createStreamingResponse(body: any): ReadableStream<Uint8Array>;
  embedding?(inputs: string | string[]): Promise<number[][]>;
  /** WebLLM sets this on fatal errors; triggers recovery path. */
  lastFatalError?: unknown;
  clearFatalError?(): void;
}

/**
 * Per-request context passed to every handler. Built once by DVAI.initialize()
 * and reused for the lifetime of the transport; handler reads the fields on
 * each request so state updates on DVAI (e.g. backendInstance replaced during
 * recovery) are visible through the same reference.
 */
export interface HandlerContext {
  /** Active backend; null means "not initialized" → 503. */
  backend: BackendInterface | null;

  /**
   * Resolved backend kind. Used only for error messages and the model
   * echo in responses. Union widens as new backends are added in later
   * phases — handlers must NOT dispatch on this value; always duck-type
   * on backend methods instead.
   */
  resolvedBackend: "webllm" | "transformers" | "native";

  /** Model identifier echoed back in responses. */
  modelId: string;

  /**
   * Optional recovery hook. Handler awaits this before a retry when
   * backend.lastFatalError is set. DVAI owns the retry counter and
   * throws when exhausted; handler only awaits. Undefined → no recovery.
   */
  onRecovery?: () => Promise<void>;
}
```

- [ ] **Step 2: Verify typecheck passes**

```bash
pnpm --filter @dvai-bridge/core exec tsc --noEmit
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add packages/dvai-bridge-core/src/handlers/context.ts
git commit -m "feat(handlers): add HandlerContext + BackendInterface types"
```

---

### Task 5: Extract `handleModels` (TDD)

**Files:**
- Create: `packages/dvai-bridge-core/src/__tests__/handlers.test.ts`
- Create: `packages/dvai-bridge-core/src/handlers/models.ts`

- [ ] **Step 1: Write the failing test**

Create `packages/dvai-bridge-core/src/__tests__/handlers.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import type { BackendInterface, HandlerContext } from "../handlers/context";

const fakeBackend: BackendInterface = {
  chatCompletion: async () => ({}),
  createStreamingResponse: () => new ReadableStream<Uint8Array>(),
};

function makeCtx(overrides: Partial<HandlerContext> = {}): HandlerContext {
  return {
    backend: fakeBackend,
    resolvedBackend: "webllm",
    modelId: "test-model",
    ...overrides,
  };
}

describe("handleModels", () => {
  it("returns an OpenAI-shaped list with the context model id", async () => {
    const { handleModels } = await import("../handlers/models");
    const res = await handleModels(makeCtx({ modelId: "gemma-2-2b-it-q4f16_1-MLC" }));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.object).toBe("list");
    expect(body.data).toHaveLength(1);
    expect(body.data[0]).toMatchObject({
      id: "gemma-2-2b-it-q4f16_1-MLC",
      object: "model",
      owned_by: "dvai-bridge",
    });
    expect(typeof body.data[0].created).toBe("number");
  });

  it("echoes whatever modelId the context provides", async () => {
    const { handleModels } = await import("../handlers/models");
    const res = await handleModels(makeCtx({ modelId: "custom-x" }));
    const body = await res.json();
    expect(body.data[0].id).toBe("custom-x");
  });
});
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
pnpm test handlers -- --run
```

Expected: FAIL — `Cannot find module '../handlers/models'`.

- [ ] **Step 3: Implement `handleModels`**

Create `packages/dvai-bridge-core/src/handlers/models.ts`:

```typescript
import type { HandlerContext } from "./context";

export async function handleModels(ctx: HandlerContext): Promise<Response> {
  return Response.json({
    object: "list",
    data: [
      {
        id: ctx.modelId,
        object: "model",
        created: Math.floor(Date.now() / 1000),
        owned_by: "dvai-bridge",
      },
    ],
  });
}
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
pnpm test handlers -- --run
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/dvai-bridge-core/src/handlers/models.ts packages/dvai-bridge-core/src/__tests__/handlers.test.ts
git commit -m "feat(handlers): extract handleModels with tests"
```

---

### Task 6: Extract `handleEmbeddings` (TDD)

**Files:**
- Create: `packages/dvai-bridge-core/src/handlers/embeddings.ts`
- Modify: `packages/dvai-bridge-core/src/__tests__/handlers.test.ts`

- [ ] **Step 1: Append failing tests to `handlers.test.ts`**

Add below the existing `describe` blocks:

```typescript
describe("handleEmbeddings", () => {
  const embeddingBackend: BackendInterface = {
    ...fakeBackend,
    embedding: async (inputs) => {
      const arr = Array.isArray(inputs) ? inputs : [inputs];
      return arr.map((_, i) => [i, i + 0.1, i + 0.2]);
    },
  };

  it("returns 503 when backend is null", async () => {
    const { handleEmbeddings } = await import("../handlers/embeddings");
    const res = await handleEmbeddings({ input: "hi" }, makeCtx({ backend: null }));
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "AI engine not initialized" });
  });

  it("returns 400 on webllm backend (unsupported)", async () => {
    const { handleEmbeddings } = await import("../handlers/embeddings");
    const res = await handleEmbeddings(
      { input: "hi" },
      makeCtx({ backend: embeddingBackend, resolvedBackend: "webllm" }),
    );
    expect(res.status).toBe(400);
    expect((await res.json()).error).toMatch(/not supported on the WebLLM backend/);
  });

  it("returns 400 when backend lacks embedding()", async () => {
    const { handleEmbeddings } = await import("../handlers/embeddings");
    const res = await handleEmbeddings(
      { input: "hi" },
      makeCtx({ backend: fakeBackend, resolvedBackend: "transformers" }),
    );
    expect(res.status).toBe(400);
    expect((await res.json()).error).toMatch(/does not support embeddings/);
  });

  it("returns 400 when input is missing", async () => {
    const { handleEmbeddings } = await import("../handlers/embeddings");
    const res = await handleEmbeddings(
      {},
      makeCtx({ backend: embeddingBackend, resolvedBackend: "transformers" }),
    );
    expect(res.status).toBe(400);
    expect((await res.json()).error).toMatch(/Missing 'input' field/);
  });

  it("returns OpenAI-shaped embeddings list on success", async () => {
    const { handleEmbeddings } = await import("../handlers/embeddings");
    const res = await handleEmbeddings(
      { input: ["hello", "world"] },
      makeCtx({ backend: embeddingBackend, resolvedBackend: "transformers", modelId: "mm" }),
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.object).toBe("list");
    expect(body.model).toBe("mm");
    expect(body.data).toHaveLength(2);
    expect(body.data[0]).toMatchObject({ object: "embedding", index: 0 });
    expect(body.data[0].embedding).toEqual([0, 0.1, 0.2]);
  });
});
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
pnpm test handlers -- --run
```

Expected: 5 `handleEmbeddings` tests FAIL (module not found).

- [ ] **Step 3: Implement `handleEmbeddings`**

Create `packages/dvai-bridge-core/src/handlers/embeddings.ts`:

```typescript
import type { HandlerContext } from "./context";

export async function handleEmbeddings(
  body: any,
  ctx: HandlerContext,
): Promise<Response> {
  if (!ctx.backend) {
    return Response.json(
      { error: "AI engine not initialized" },
      { status: 503 },
    );
  }
  if (ctx.resolvedBackend === "webllm") {
    return Response.json(
      {
        error:
          "Embeddings are not supported on the WebLLM backend. " +
          "Use backend: 'transformers' with pipelineTask: 'feature-extraction', " +
          "or backend: 'native' with nativeEmbeddingMode: true.",
      },
      { status: 400 },
    );
  }
  if (typeof ctx.backend.embedding !== "function") {
    return Response.json(
      {
        error:
          "The current backend does not support embeddings. " +
          "For transformers: use pipelineTask: 'feature-extraction'. " +
          "For native: set nativeEmbeddingMode: true.",
      },
      { status: 400 },
    );
  }

  const input = body?.input;
  if (input === undefined || input === null) {
    return Response.json(
      { error: "Missing 'input' field." },
      { status: 400 },
    );
  }

  try {
    const vectors: number[][] = await ctx.backend.embedding(input);
    return Response.json({
      object: "list",
      data: vectors.map((v, i) => ({
        object: "embedding",
        embedding: v,
        index: i,
      })),
      model: body.model || ctx.modelId,
      usage: { prompt_tokens: 0, total_tokens: 0 },
    });
  } catch (error: any) {
    return Response.json({ error: error.message }, { status: 500 });
  }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
pnpm test handlers -- --run
```

Expected: all handleEmbeddings tests pass, existing handleModels tests still pass.

- [ ] **Step 5: Commit**

```bash
git add packages/dvai-bridge-core/src/handlers/embeddings.ts packages/dvai-bridge-core/src/__tests__/handlers.test.ts
git commit -m "feat(handlers): extract handleEmbeddings with tests"
```

---

### Task 7: Extract `handleCompletion` + move legacy helpers (TDD)

**Files:**
- Create: `packages/dvai-bridge-core/src/handlers/completions.ts`
- Modify: `packages/dvai-bridge-core/src/__tests__/handlers.test.ts`
- Modify: `packages/dvai-bridge-core/src/index.ts` (re-export legacy helpers from new location)

- [ ] **Step 1: Append failing tests to `handlers.test.ts`**

Add below the existing `describe` blocks:

```typescript
describe("handleCompletion (legacy)", () => {
  const canned = {
    id: "chatcmpl-abc",
    object: "chat.completion",
    created: 1700000000,
    model: "m",
    choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
  };
  const completionBackend: BackendInterface = {
    chatCompletion: async () => canned,
    createStreamingResponse: () => new ReadableStream<Uint8Array>(),
  };

  it("returns 503 when backend is null", async () => {
    const { handleCompletion } = await import("../handlers/completions");
    const res = await handleCompletion({ prompt: "x" }, makeCtx({ backend: null }));
    expect(res.status).toBe(503);
  });

  it("converts prompt to messages, returns text_completion shape", async () => {
    const { handleCompletion } = await import("../handlers/completions");
    const res = await handleCompletion(
      { prompt: "hi", model: "m" },
      makeCtx({ backend: completionBackend, modelId: "m" }),
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.object).toBe("text_completion");
    expect(body.id).toBe("cmpl-abc");
    expect(body.choices[0].text).toBe("hi");
  });

  it("joins prompt arrays with newlines", async () => {
    const { handleCompletion } = await import("../handlers/completions");
    let capturedBody: any;
    const capturing: BackendInterface = {
      ...completionBackend,
      chatCompletion: async (body) => { capturedBody = body; return canned; },
    };
    await handleCompletion(
      { prompt: ["line1", "line2"], model: "m" },
      makeCtx({ backend: capturing }),
    );
    expect(capturedBody.messages[0].content).toBe("line1\nline2");
    expect("prompt" in capturedBody).toBe(false);
  });
});

describe("legacy helpers (re-exported from completions)", () => {
  it("chatToLegacyCompletion converts basic shape", async () => {
    const { chatToLegacyCompletion } = await import("../handlers/completions");
    const out = chatToLegacyCompletion({
      id: "chatcmpl-1",
      created: 100,
      model: "m",
      choices: [{ index: 0, message: { content: "x" }, finish_reason: "stop" }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    });
    expect(out.object).toBe("text_completion");
    expect(out.id).toBe("cmpl-1");
    expect(out.choices[0].text).toBe("x");
  });
});
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
pnpm test handlers -- --run
```

Expected: new tests FAIL (module not found).

- [ ] **Step 3: Implement `handleCompletion` + move legacy helpers**

Create `packages/dvai-bridge-core/src/handlers/completions.ts`:

```typescript
import type { HandlerContext } from "./context";

/**
 * Convert an OpenAI chat.completion response body into the legacy
 * text_completion shape used by POST /v1/completions.
 */
export function chatToLegacyCompletion(chatResp: any): any {
  return {
    id:
      (chatResp.id || "").replace("chatcmpl-", "cmpl-") || `cmpl-${Date.now()}`,
    object: "text_completion",
    created: chatResp.created ?? Math.floor(Date.now() / 1000),
    model: chatResp.model,
    choices: (chatResp.choices || []).map((c: any) => ({
      text: c.message?.content ?? "",
      index: c.index ?? 0,
      finish_reason: c.finish_reason ?? "stop",
      logprobs: null,
    })),
    usage: chatResp.usage ?? {
      prompt_tokens: 0,
      completion_tokens: 0,
      total_tokens: 0,
    },
  };
}

/**
 * Wraps an SSE stream of chat.completion.chunk events and rewrites each
 * event as a legacy text_completion chunk. Preserves event boundaries.
 */
export function legacyCompletionStreamAdapter(
  chatStream: ReadableStream<Uint8Array>,
  model: string,
): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  let buffer = "";

  return new ReadableStream<Uint8Array>({
    async start(controller) {
      const reader = chatStream.getReader();
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });

          let idx: number;
          while ((idx = buffer.indexOf("\n\n")) !== -1) {
            const rawEvent = buffer.slice(0, idx);
            buffer = buffer.slice(idx + 2);
            const dataLine = rawEvent
              .split("\n")
              .find((l) => l.startsWith("data:"));
            if (!dataLine) continue;
            const payload = dataLine.slice("data:".length).trim();
            if (payload === "[DONE]") {
              controller.enqueue(encoder.encode("data: [DONE]\n\n"));
              continue;
            }
            try {
              const chunk = JSON.parse(payload);
              const legacyChunk = {
                id: (chunk.id || "").replace("chatcmpl-", "cmpl-"),
                object: "text_completion.chunk",
                created: chunk.created,
                model: chunk.model || model,
                choices: (chunk.choices || []).map((c: any) => ({
                  text: c.delta?.content ?? "",
                  index: c.index ?? 0,
                  finish_reason: c.finish_reason ?? null,
                  logprobs: null,
                })),
              };
              controller.enqueue(
                encoder.encode(`data: ${JSON.stringify(legacyChunk)}\n\n`),
              );
            } catch {
              controller.enqueue(encoder.encode(`data: ${payload}\n\n`));
            }
          }
        }
      } finally {
        controller.close();
      }
    },
  });
}

export async function handleCompletion(
  body: any,
  ctx: HandlerContext,
): Promise<Response> {
  if (!ctx.backend) {
    return Response.json(
      { error: "AI engine not initialized" },
      { status: 503 },
    );
  }

  const promptField = body.prompt;
  const prompt = Array.isArray(promptField)
    ? promptField.join("\n")
    : (promptField ?? "");
  const chatBody = {
    ...body,
    messages: [{ role: "user", content: prompt }],
  };
  delete chatBody.prompt;

  try {
    if (chatBody.stream) {
      const chatStream = ctx.backend.createStreamingResponse(chatBody);
      const legacyStream = legacyCompletionStreamAdapter(
        chatStream,
        body.model || ctx.modelId,
      );
      return new Response(legacyStream, {
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        },
      });
    }
    const chatResp = await ctx.backend.chatCompletion(chatBody);
    return Response.json(chatToLegacyCompletion(chatResp));
  } catch (error: any) {
    return Response.json({ error: error.message }, { status: 500 });
  }
}
```

- [ ] **Step 4: Update `src/index.ts` to re-export legacy helpers from new location**

Replace the top block in `packages/dvai-bridge-core/src/index.ts` (lines ~13-102 — the two inline legacy helper functions) with a re-export:

```typescript
// Re-export legacy helpers from the handlers module for backward compat.
// Existing tests/consumers import these from "@dvai-bridge/core".
export {
  chatToLegacyCompletion,
  legacyCompletionStreamAdapter,
} from "./handlers/completions.js";
```

Leave everything else in `index.ts` (including the still-inline `buildMswHandlers`) unchanged. The handlers module now owns the source of truth; the old inline copies are deleted.

- [ ] **Step 5: Update the body of `buildMswHandlers` to call the moved helpers**

Inside `buildMswHandlers` in `packages/dvai-bridge-core/src/index.ts`, find the `handleCompletion` arrow function (lines ~455-495) and replace its body's references to `chatToLegacyCompletion` and `legacyCompletionStreamAdapter` with imports from the new location. Add this import at the top of `index.ts`:

```typescript
import {
  chatToLegacyCompletion,
  legacyCompletionStreamAdapter,
} from "./handlers/completions.js";
```

(The existing inline arrow functions inside `buildMswHandlers` keep working — they now call the imported helpers.)

- [ ] **Step 6: Run all tests**

```bash
pnpm test -- --run
```

Expected: all handler tests pass. Existing `completions-legacy.test.ts` still passes (the legacy helpers are still exported from the public entry).

- [ ] **Step 7: Commit**

```bash
git add packages/dvai-bridge-core/src/handlers/completions.ts packages/dvai-bridge-core/src/__tests__/handlers.test.ts packages/dvai-bridge-core/src/index.ts
git commit -m "feat(handlers): extract handleCompletion and legacy helpers"
```

---

### Task 8: Extract `handleChatCompletion` (TDD)

**Files:**
- Create: `packages/dvai-bridge-core/src/handlers/chat.ts`
- Modify: `packages/dvai-bridge-core/src/__tests__/handlers.test.ts`

- [ ] **Step 1: Append failing tests to `handlers.test.ts`**

Add below the existing `describe` blocks:

```typescript
describe("handleChatCompletion", () => {
  const canned = {
    id: "chatcmpl-fixed",
    object: "chat.completion",
    created: 1700000000,
    model: "m",
    choices: [{ index: 0, message: { role: "assistant", content: "canned" }, finish_reason: "stop" }],
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
  };
  const chatBackend: BackendInterface = {
    chatCompletion: async () => canned,
    createStreamingResponse: () => {
      const encoder = new TextEncoder();
      return new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify({ id: "chatcmpl-fixed", choices: [{ delta: { content: "hi" }, index: 0 }] })}\n\n`));
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        },
      });
    },
  };

  it("returns 503 when backend is null", async () => {
    const { handleChatCompletion } = await import("../handlers/chat");
    const res = await handleChatCompletion({ messages: [] }, makeCtx({ backend: null }));
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "AI engine not initialized" });
  });

  it("returns the canned chat.completion on success (non-stream)", async () => {
    const { handleChatCompletion } = await import("../handlers/chat");
    const res = await handleChatCompletion(
      { messages: [{ role: "user", content: "hi" }] },
      makeCtx({ backend: chatBackend }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ id: "chatcmpl-fixed" });
  });

  it("returns SSE response with event-stream headers on stream=true", async () => {
    const { handleChatCompletion } = await import("../handlers/chat");
    const res = await handleChatCompletion(
      { stream: true, messages: [{ role: "user", content: "hi" }] },
      makeCtx({ backend: chatBackend }),
    );
    expect(res.headers.get("content-type")).toBe("text/event-stream");
    const text = await res.text();
    expect(text).toContain("data: [DONE]");
  });

  it("calls onRecovery when backend has lastFatalError pre-request", async () => {
    const { handleChatCompletion } = await import("../handlers/chat");
    const backendWithFatal: BackendInterface = {
      ...chatBackend,
      lastFatalError: "blank_output",
    };
    let recoveryCalls = 0;
    await handleChatCompletion(
      { messages: [{ role: "user", content: "hi" }] },
      makeCtx({
        backend: backendWithFatal,
        onRecovery: async () => { recoveryCalls++; },
      }),
    );
    expect(recoveryCalls).toBe(1);
  });

  it("returns 500 with error.message when backend throws and recovery fails", async () => {
    const { handleChatCompletion } = await import("../handlers/chat");
    const throwingBackend: BackendInterface = {
      ...chatBackend,
      chatCompletion: async () => { throw new Error("boom"); },
    };
    const res = await handleChatCompletion(
      { messages: [] },
      makeCtx({ backend: throwingBackend }),
    );
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: "boom" });
  });
});
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
pnpm test handlers -- --run
```

Expected: 5 new tests FAIL (module not found).

- [ ] **Step 3: Implement `handleChatCompletion`**

Create `packages/dvai-bridge-core/src/handlers/chat.ts`:

```typescript
import type { HandlerContext } from "./context";

const SSE_HEADERS = {
  "Content-Type": "text/event-stream",
  "Cache-Control": "no-cache",
  Connection: "keep-alive",
};

export async function handleChatCompletion(
  body: any,
  ctx: HandlerContext,
): Promise<Response> {
  if (!ctx.backend) {
    return Response.json(
      { error: "AI engine not initialized" },
      { status: 503 },
    );
  }

  const backend = ctx.backend;

  const runOnce = async (): Promise<Response> => {
    if (body.stream) {
      const stream = backend.createStreamingResponse(body);
      return new Response(stream, { headers: SSE_HEADERS });
    }
    const response = await backend.chatCompletion(body);
    return Response.json(response);
  };

  try {
    // Proactive recovery: if the backend is flagged with a prior fatal error,
    // ask DVAI to recover before the attempt.
    if (backend.lastFatalError && ctx.onRecovery) {
      await ctx.onRecovery();
    }
    return await runOnce();
  } catch (error: any) {
    // Reactive recovery: if the backend flags a fatal error during the attempt,
    // recover and retry once. DVAI's onRecovery throws when exhausted, which
    // falls through to the 500 response below.
    if (ctx.backend?.lastFatalError && ctx.onRecovery) {
      try {
        await ctx.onRecovery();
        return await runOnce();
      } catch {
        /* fall through to 500 */
      }
    }
    return Response.json({ error: error.message }, { status: 500 });
  }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
pnpm test handlers -- --run
```

Expected: all handler tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/dvai-bridge-core/src/handlers/chat.ts packages/dvai-bridge-core/src/__tests__/handlers.test.ts
git commit -m "feat(handlers): extract handleChatCompletion with tests"
```

---

### Task 9: Barrel + rewire `buildMswHandlers` to use new handlers

**Files:**
- Create: `packages/dvai-bridge-core/src/handlers/index.ts`
- Modify: `packages/dvai-bridge-core/src/index.ts`

- [ ] **Step 1: Create the barrel**

Create `packages/dvai-bridge-core/src/handlers/index.ts`:

```typescript
export type { BackendInterface, HandlerContext } from "./context.js";
export { handleChatCompletion } from "./chat.js";
export {
  handleCompletion,
  chatToLegacyCompletion,
  legacyCompletionStreamAdapter,
} from "./completions.js";
export { handleEmbeddings } from "./embeddings.js";
export { handleModels } from "./models.js";
```

- [ ] **Step 2: Add `getHandlerContext` and rewire `buildMswHandlers` in `src/index.ts`**

In `packages/dvai-bridge-core/src/index.ts`, add the import near the top:

```typescript
import {
  handleChatCompletion,
  handleCompletion,
  handleEmbeddings,
  handleModels,
  type HandlerContext,
} from "./handlers/index.js";
```

Add this private method on the `DVAI` class (place it right above the existing `buildMswHandlers` method, around line ~389):

```typescript
/**
 * Builds the HandlerContext consumed by all transport-agnostic handlers.
 * Captures `this` so state updates (e.g. backendInstance replaced during
 * recovery) are visible through the same reference on subsequent requests.
 */
private getHandlerContext(
  onProgress: (info: any) => void,
): HandlerContext {
  return {
    backend: this.backendInstance,
    resolvedBackend: this.resolvedBackend,
    modelId:
      this.resolvedBackend === "transformers" ? this.transformersModelId :
      this.resolvedBackend === "native"       ? this.nativeModelPath :
                                                this.modelId,
    onRecovery:
      this.resolvedBackend === "webllm"
        ? async () => {
            if (
              this.backendInstance?.lastFatalError &&
              this.recoveryAttempts < this.maxRetries
            ) {
              await this.attemptRecovery(onProgress);
            } else if (this.recoveryAttempts >= this.maxRetries) {
              throw new Error("Recovery exhausted");
            }
          }
        : undefined,
  };
}
```

Replace the entire body of `buildMswHandlers` (currently ~200 lines, line ~392-592) with the thin wrapper:

```typescript
private buildMswHandlers(onProgress: (info: any) => void): any[] {
  const urls = this.getEndpoints();
  const ctx = this.getHandlerContext(onProgress);
  return [
    http.post(urls.chat, async ({ request }) =>
      handleChatCompletion(await request.json(), ctx),
    ),
    http.post(urls.completions, async ({ request }) =>
      handleCompletion(await request.json(), ctx),
    ),
    http.post(urls.embeddings, async ({ request }) =>
      handleEmbeddings(await request.json(), ctx),
    ),
    http.get(urls.models, async () => handleModels(ctx)),
  ];
}
```

Remove the unused `HttpResponse` import from `msw` if it's no longer referenced. Leave the `http` import — still used for route registration.

- [ ] **Step 3: Run all tests**

```bash
pnpm test -- --run
```

Expected: all tests pass — handler tests from Tasks 5-8 plus existing config/embeddings/completions-legacy/blank-detection tests.

- [ ] **Step 4: Build the package**

```bash
pnpm --filter @dvai-bridge/core build
```

Expected: success.

- [ ] **Step 5: Commit**

```bash
git add packages/dvai-bridge-core/src/handlers/index.ts packages/dvai-bridge-core/src/index.ts
git commit -m "refactor(core): wire buildMswHandlers through transport-agnostic handlers"
```

---

## Phase C — Transport layer (TDD)

### Task 10: `port-fallback.ts` (TDD)

**Files:**
- Create: `packages/dvai-bridge-core/src/__tests__/port-fallback.test.ts`
- Create: `packages/dvai-bridge-core/src/transports/port-fallback.ts`

- [ ] **Step 1: Write the failing tests**

Create `packages/dvai-bridge-core/src/__tests__/port-fallback.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { createServer } from "node:http";

// Use a dedicated high range for tests so we don't collide with a
// dev-running DVAI on the default base port (38883).
const TEST_BASE = 39001;

describe("tryBind", () => {
  it("binds to the base port when free", async () => {
    const { tryBind } = await import("../transports/port-fallback");
    const server = createServer();
    try {
      const port = await tryBind(server, TEST_BASE, 4);
      expect(port).toBe(TEST_BASE);
    } finally {
      await new Promise<void>((r) => server.close(() => r()));
    }
  });

  it("retries +1 on EADDRINUSE and returns the next free port", async () => {
    const { tryBind } = await import("../transports/port-fallback");
    const blocker = createServer();
    await new Promise<void>((r) => blocker.listen(TEST_BASE + 10, "127.0.0.1", r));

    const server = createServer();
    try {
      const port = await tryBind(server, TEST_BASE + 10, 4);
      expect(port).toBe(TEST_BASE + 11);
    } finally {
      await new Promise<void>((r) => server.close(() => r()));
      await new Promise<void>((r) => blocker.close(() => r()));
    }
  });

  it("throws with actionable message after max attempts all blocked", async () => {
    const { tryBind } = await import("../transports/port-fallback");
    // Occupy TEST_BASE+20..TEST_BASE+23
    const blockers = await Promise.all(
      [0, 1, 2, 3].map((i) => {
        const s = createServer();
        return new Promise<typeof s>((r) => s.listen(TEST_BASE + 20 + i, "127.0.0.1", () => r(s)));
      }),
    );

    const server = createServer();
    try {
      await expect(tryBind(server, TEST_BASE + 20, 4)).rejects.toThrow(
        new RegExp(`${TEST_BASE + 20}\\.\\.${TEST_BASE + 23}`),
      );
    } finally {
      for (const b of blockers) await new Promise<void>((r) => b.close(() => r()));
    }
  });

  it("exports BASE_PORT = 38883 and MAX_PORT_ATTEMPTS = 16", async () => {
    const { BASE_PORT, MAX_PORT_ATTEMPTS } = await import("../transports/port-fallback");
    expect(BASE_PORT).toBe(38883);
    expect(MAX_PORT_ATTEMPTS).toBe(16);
  });
});
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
pnpm test port-fallback -- --run
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement `port-fallback.ts`**

Create `packages/dvai-bridge-core/src/transports/port-fallback.ts`:

```typescript
import type { Server } from "node:http";

/** DVAI-reserved base port. Deliberately high to avoid clashes with Ollama/Postgres/etc. */
export const BASE_PORT = 38883;

/** Maximum port-fallback attempts before giving up. */
export const MAX_PORT_ATTEMPTS = 16;

/**
 * Attempt to bind `server` to `basePort`, falling back to basePort+1,
 * basePort+2, ... on EADDRINUSE up to `maxAttempts` times.
 *
 * Throws a loud, actionable error listing the tried range if all are in use.
 * Re-throws non-EADDRINUSE errors immediately (e.g. EACCES on privileged ports).
 *
 * @returns the port that was successfully bound
 */
export async function tryBind(
  server: Server,
  basePort: number = BASE_PORT,
  maxAttempts: number = MAX_PORT_ATTEMPTS,
  host: string = "127.0.0.1",
): Promise<number> {
  for (let i = 0; i < maxAttempts; i++) {
    const port = basePort + i;
    try {
      await new Promise<void>((resolve, reject) => {
        const onError = (err: any) => {
          server.off("error", onError);
          reject(err);
        };
        server.once("error", onError);
        server.listen(port, host, () => {
          server.off("error", onError);
          resolve();
        });
      });
      return port;
    } catch (err: any) {
      if (err.code !== "EADDRINUSE") throw err;
    }
  }
  throw new Error(
    `[DVAI] Could not bind HTTP transport to any port in range ` +
      `${basePort}..${basePort + maxAttempts - 1} (all in use). ` +
      `Another local AI server may already be running.`,
  );
}
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
pnpm test port-fallback -- --run
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/dvai-bridge-core/src/transports/port-fallback.ts packages/dvai-bridge-core/src/__tests__/port-fallback.test.ts
git commit -m "feat(transports): add port-fallback helper with BASE_PORT=38883"
```

---

### Task 11: `transports/types.ts`

**Files:**
- Create: `packages/dvai-bridge-core/src/transports/types.ts`

- [ ] **Step 1: Create the types file**

```typescript
import type { HandlerContext } from "../handlers/context.js";

export type TransportKind = "msw" | "http" | "none";

export interface TransportStartResult {
  /** URL a host app hands to an OpenAI SDK (no trailing slash). */
  baseUrl: string;
  /** Populated only for http transport; undefined for msw/none. */
  port?: number;
}

export interface Transport {
  readonly kind: TransportKind;
  start(ctx: HandlerContext): Promise<TransportStartResult>;
  /** Idempotent; safe to call multiple times. */
  stop(): Promise<void>;
}

export interface HttpTransportOptions {
  httpBasePort: number;
  httpMaxPortAttempts: number;
  corsOrigin: string | string[];
}

export interface MswTransportOptions {
  /** URL MSW intercepts, including /v1/chat/completions suffix. */
  mockUrl: string;
  /** Path to the msw service worker script. */
  serviceWorkerUrl: string;
}
```

- [ ] **Step 2: Verify typecheck**

```bash
pnpm --filter @dvai-bridge/core exec tsc --noEmit
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add packages/dvai-bridge-core/src/transports/types.ts
git commit -m "feat(transports): add Transport interface and options types"
```

---

### Task 12: Extract MSW logic → `transports/msw.ts`

**Files:**
- Create: `packages/dvai-bridge-core/src/transports/msw.ts`
- Modify: `packages/dvai-bridge-core/src/__tests__/transport.test.ts` (create)

- [ ] **Step 1: Write failing smoke test**

Create `packages/dvai-bridge-core/src/__tests__/transport.test.ts`:

```typescript
// @vitest-environment happy-dom
import { describe, it, expect } from "vitest";
import type { HandlerContext, BackendInterface } from "../handlers/context";

const fakeBackend: BackendInterface = {
  chatCompletion: async () => ({ id: "x", choices: [] }),
  createStreamingResponse: () => new ReadableStream<Uint8Array>(),
};
const ctx: HandlerContext = {
  backend: fakeBackend,
  resolvedBackend: "webllm",
  modelId: "test",
};

describe("MswTransport", () => {
  it("reports kind=msw and returns a baseUrl derived from mockUrl", async () => {
    const { MswTransport } = await import("../transports/msw");
    const t = new MswTransport({
      mockUrl: "https://api.openai.local/v1/chat/completions",
      serviceWorkerUrl: "", // empty skips SW registration for this smoke test
    });
    expect(t.kind).toBe("msw");
    // start() with empty serviceWorkerUrl must not register a SW; baseUrl still derives
    const result = await t.start(ctx);
    expect(result.baseUrl).toBe("https://api.openai.local/v1");
    expect(result.port).toBeUndefined();
    await t.stop();
  });
});
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
pnpm test transport -- --run
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement `MswTransport`**

Create `packages/dvai-bridge-core/src/transports/msw.ts`:

```typescript
import { setupWorker, type SetupWorker } from "msw/browser";
import { http } from "msw";
import type { HandlerContext } from "../handlers/context.js";
import {
  handleChatCompletion,
  handleCompletion,
  handleEmbeddings,
  handleModels,
} from "../handlers/index.js";
import type {
  MswTransportOptions,
  Transport,
  TransportStartResult,
} from "./types.js";

function getEndpoints(mockUrl: string): {
  chat: string;
  completions: string;
  embeddings: string;
  models: string;
  base: string;
} {
  const chat = mockUrl;
  let base = chat;
  const chatSuffix = "/chat/completions";
  if (chat.endsWith(chatSuffix)) {
    base = chat.slice(0, -chatSuffix.length);
  } else {
    try {
      const u = new URL(chat);
      const parts = u.pathname.split("/").filter(Boolean);
      parts.pop();
      u.pathname = "/" + parts.join("/");
      base = u.toString().replace(/\/$/, "");
    } catch {
      /* keep base = chat */
    }
  }
  return {
    chat,
    completions: `${base}/completions`,
    embeddings: `${base}/embeddings`,
    models: `${base}/models`,
    base,
  };
}

export class MswTransport implements Transport {
  readonly kind = "msw" as const;
  private worker: SetupWorker | null = null;

  constructor(private readonly opts: MswTransportOptions) {}

  async start(ctx: HandlerContext): Promise<TransportStartResult> {
    const urls = getEndpoints(this.opts.mockUrl);

    // Empty serviceWorkerUrl means "don't register" — preserves the
    // direct-inference escape hatch while still reporting a baseUrl.
    if (this.opts.serviceWorkerUrl) {
      const handlers = [
        http.post(urls.chat, async ({ request }) =>
          handleChatCompletion(await request.json(), ctx),
        ),
        http.post(urls.completions, async ({ request }) =>
          handleCompletion(await request.json(), ctx),
        ),
        http.post(urls.embeddings, async ({ request }) =>
          handleEmbeddings(await request.json(), ctx),
        ),
        http.get(urls.models, async () => handleModels(ctx)),
      ];
      this.worker = setupWorker(...handlers);
      await this.worker.start({
        onUnhandledRequest: "bypass",
        serviceWorker: { url: this.opts.serviceWorkerUrl },
      } as any);
    }

    return { baseUrl: urls.base };
  }

  async stop(): Promise<void> {
    if (this.worker) {
      this.worker.stop();
      this.worker = null;
    }
  }
}
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
pnpm test transport -- --run
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add packages/dvai-bridge-core/src/transports/msw.ts packages/dvai-bridge-core/src/__tests__/transport.test.ts
git commit -m "feat(transports): extract MswTransport from DVAI class"
```

---

### Task 13: `transports/http.ts` (TDD — smoke only; full equivalence in Task 18)

**Files:**
- Create: `packages/dvai-bridge-core/src/transports/http.ts`
- Modify: `packages/dvai-bridge-core/src/__tests__/transport.test.ts`

- [ ] **Step 1: Append failing smoke tests to `transport.test.ts`**

Add a new `describe` block below the existing one (the file-level `@vitest-environment happy-dom` directive still applies; we test the HTTP transport in a separate `.http.test.ts` file in Task 18 to give it a clean Node env):

```typescript
describe("HttpTransport (lightweight smoke)", () => {
  it("reports kind=http", async () => {
    const { HttpTransport } = await import("../transports/http");
    const t = new HttpTransport({
      httpBasePort: 39100,
      httpMaxPortAttempts: 1,
      corsOrigin: "*",
    });
    expect(t.kind).toBe("http");
  });
});
```

The full equivalence tests (request/response, CORS headers, streaming) live in Task 18 in a node-env file.

- [ ] **Step 2: Run the test and verify it fails**

```bash
pnpm test transport -- --run
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement `HttpTransport`**

Create `packages/dvai-bridge-core/src/transports/http.ts`:

```typescript
import type { HandlerContext } from "../handlers/context.js";
import {
  handleChatCompletion,
  handleCompletion,
  handleEmbeddings,
  handleModels,
} from "../handlers/index.js";
import type {
  HttpTransportOptions,
  Transport,
  TransportStartResult,
} from "./types.js";
import { tryBind } from "./port-fallback.js";

type NodeReq = import("node:http").IncomingMessage;
type NodeRes = import("node:http").ServerResponse;
type NodeServer = import("node:http").Server;

function pickOrigin(origin: string | undefined, cfg: string | string[]): string | null {
  if (cfg === "*") return "*";
  if (typeof cfg === "string") return cfg;
  if (!origin) return null;
  return cfg.includes(origin) ? origin : null;
}

function corsHeaders(
  reqOrigin: string | undefined,
  cfg: string | string[],
): Record<string, string> {
  const allow = pickOrigin(reqOrigin, cfg);
  const headers: Record<string, string> = {
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Private-Network": "true",
  };
  if (allow) headers["Access-Control-Allow-Origin"] = allow;
  return headers;
}

async function readJsonBody(req: NodeReq): Promise<any> {
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(c as Buffer);
  const raw = Buffer.concat(chunks).toString("utf8");
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error("Invalid JSON body");
  }
}

async function writeWhatwgResponse(
  res: NodeRes,
  response: Response,
  extraHeaders: Record<string, string>,
): Promise<void> {
  const headers: Record<string, string> = { ...extraHeaders };
  response.headers.forEach((v, k) => {
    headers[k] = v;
  });

  if (response.body) {
    res.writeHead(response.status, headers);
    const reader = response.body.getReader();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        res.write(Buffer.from(value));
      }
    } finally {
      res.end();
    }
    return;
  }
  const text = await response.text();
  res.writeHead(response.status, headers);
  res.end(text);
}

async function route(
  req: NodeReq,
  res: NodeRes,
  ctx: HandlerContext,
  opts: HttpTransportOptions,
): Promise<void> {
  const reqOrigin = req.headers.origin as string | undefined;
  const cors = corsHeaders(reqOrigin, opts.corsOrigin);

  if (req.method === "OPTIONS") {
    res.writeHead(204, cors);
    res.end();
    return;
  }

  const url = new URL(req.url || "/", "http://127.0.0.1");
  const path = url.pathname;

  try {
    if (req.method === "POST" && path === "/v1/chat/completions") {
      const body = await readJsonBody(req);
      const r = await handleChatCompletion(body, ctx);
      return writeWhatwgResponse(res, r, cors);
    }
    if (req.method === "POST" && path === "/v1/completions") {
      const body = await readJsonBody(req);
      const r = await handleCompletion(body, ctx);
      return writeWhatwgResponse(res, r, cors);
    }
    if (req.method === "POST" && path === "/v1/embeddings") {
      const body = await readJsonBody(req);
      const r = await handleEmbeddings(body, ctx);
      return writeWhatwgResponse(res, r, cors);
    }
    if (req.method === "GET" && path === "/v1/models") {
      const r = await handleModels(ctx);
      return writeWhatwgResponse(res, r, cors);
    }
    res.writeHead(404, { ...cors, "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "not found" }));
  } catch (err: any) {
    res.writeHead(500, { ...cors, "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: err?.message ?? "unknown error" }));
  }
}

export class HttpTransport implements Transport {
  readonly kind = "http" as const;
  private server: NodeServer | null = null;
  private boundPort: number | undefined;

  constructor(private readonly opts: HttpTransportOptions) {}

  async start(ctx: HandlerContext): Promise<TransportStartResult> {
    const { createServer } = await import("node:http");
    const server = createServer((req, res) => {
      route(req, res, ctx, this.opts).catch((err) => {
        try {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: (err as Error).message }));
        } catch {
          /* socket already closed */
        }
      });
    });
    const port = await tryBind(server, this.opts.httpBasePort, this.opts.httpMaxPortAttempts);
    this.server = server;
    this.boundPort = port;
    return { baseUrl: `http://127.0.0.1:${port}/v1`, port };
  }

  async stop(): Promise<void> {
    if (this.server) {
      await new Promise<void>((r) => this.server!.close(() => r()));
      this.server = null;
      this.boundPort = undefined;
    }
  }
}
```

- [ ] **Step 4: Run tests and verify the smoke test passes**

```bash
pnpm test transport -- --run
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add packages/dvai-bridge-core/src/transports/http.ts packages/dvai-bridge-core/src/__tests__/transport.test.ts
git commit -m "feat(transports): add HttpTransport with CORS + PNA headers"
```

---

### Task 14: `transports/index.ts` with `selectTransport`

**Files:**
- Create: `packages/dvai-bridge-core/src/transports/index.ts`

- [ ] **Step 1: Create the barrel + selection logic**

```typescript
export type {
  Transport,
  TransportKind,
  TransportStartResult,
  HttpTransportOptions,
  MswTransportOptions,
} from "./types.js";
export { MswTransport } from "./msw.js";
export { HttpTransport } from "./http.js";
export { BASE_PORT, MAX_PORT_ATTEMPTS, tryBind } from "./port-fallback.js";

export interface SelectTransportInput {
  /** Raw config: "auto" | "msw" | "http" | "none", or undefined. */
  transport?: "auto" | "msw" | "http" | "none";
  /** Back-compat signal: "" disables transport when transport is not explicit. */
  serviceWorkerUrl?: string;
}

/** Resolve "auto" based on the runtime environment. */
export function selectTransport(
  input: SelectTransportInput,
): "msw" | "http" | "none" {
  // Back-compat escape hatch: empty serviceWorkerUrl with no explicit transport → none
  if (input.serviceWorkerUrl === "" && input.transport == null) return "none";
  const requested = input.transport ?? "auto";
  if (requested !== "auto") return requested;
  if (isBrowserLike()) return "msw";
  if (isNode()) return "http";
  return "none";
}

function isBrowserLike(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof document !== "undefined" &&
    typeof navigator !== "undefined" &&
    typeof (navigator as any).serviceWorker !== "undefined"
  );
}

function isNode(): boolean {
  return (
    typeof process !== "undefined" &&
    process.versions != null &&
    process.versions.node != null
  );
}
```

- [ ] **Step 2: Add selection tests to `transport.test.ts`**

Append to `packages/dvai-bridge-core/src/__tests__/transport.test.ts`:

```typescript
describe("selectTransport", () => {
  it("returns explicit value unchanged when not auto", async () => {
    const { selectTransport } = await import("../transports/index");
    expect(selectTransport({ transport: "http" })).toBe("http");
    expect(selectTransport({ transport: "msw" })).toBe("msw");
    expect(selectTransport({ transport: "none" })).toBe("none");
  });

  it("preserves serviceWorkerUrl:'' back-compat escape hatch", async () => {
    const { selectTransport } = await import("../transports/index");
    expect(selectTransport({ serviceWorkerUrl: "" })).toBe("none");
  });

  it("explicit transport wins over empty serviceWorkerUrl", async () => {
    const { selectTransport } = await import("../transports/index");
    expect(selectTransport({ transport: "msw", serviceWorkerUrl: "" })).toBe("msw");
  });

  it("resolves auto to msw in browser-like env (happy-dom)", async () => {
    const { selectTransport } = await import("../transports/index");
    // happy-dom provides window, document, navigator.serviceWorker stub
    expect(selectTransport({ transport: "auto" })).toBe("msw");
  });
});
```

- [ ] **Step 3: Run tests and verify they pass**

```bash
pnpm test transport -- --run
```

Expected: all selection tests pass.

- [ ] **Step 4: Commit**

```bash
git add packages/dvai-bridge-core/src/transports/index.ts packages/dvai-bridge-core/src/__tests__/transport.test.ts
git commit -m "feat(transports): add selectTransport with env detection"
```

---

## Phase D — DVAI integration

### Task 15: Add new config fields to `DVAIConfig`

**Files:**
- Modify: `packages/dvai-bridge-core/src/index.ts`

- [ ] **Step 1: Add fields to `DVAIConfig`**

In `packages/dvai-bridge-core/src/index.ts`, find the `DVAIConfig` interface (starts around line 112). Add these fields just before the closing brace (right after the existing `autoInit?: boolean;` line):

```typescript
  /**
   * Which transport to use for the OpenAI-compatible surface.
   * - "auto"  (default) → msw in browser, http in Node, none in workers
   * - "msw"  → force MSW (browser only; errors elsewhere)
   * - "http" → force HTTP server (Node only; errors elsewhere)
   * - "none" → no transport; use dvai.chatCompletion() directly
   */
  transport?: "auto" | "msw" | "http" | "none";

  /** HTTP-only. Base port. Default: 38883. */
  httpBasePort?: number;

  /** HTTP-only. Max port-fallback attempts. Default: 16. */
  httpMaxPortAttempts?: number;

  /**
   * HTTP-only. Controls the Access-Control-Allow-Origin response header.
   * - "*"               → echo "*" (default; dev-friendly)
   * - "https://x.com"   → echo that exact origin
   * - ["a.com","b.com"] → match the request's Origin header against the
   *                        list; echo the matched value. Requests from
   *                        unlisted origins get ACAO omitted.
   */
  corsOrigin?: string | string[];
```

- [ ] **Step 2: Verify typecheck**

```bash
pnpm --filter @dvai-bridge/core exec tsc --noEmit
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add packages/dvai-bridge-core/src/index.ts
git commit -m "feat(core): add transport + http config options to DVAIConfig"
```

---

### Task 16: Store config + add public fields/methods on `DVAI`

**Files:**
- Modify: `packages/dvai-bridge-core/src/index.ts`

- [ ] **Step 1: Add instance fields and setters for new config**

Inside the `DVAI` class, alongside the existing field declarations (after `public nativeEmbeddingMode: boolean;`), add:

```typescript
  /** Raw transport config (e.g., "auto"). */
  public transport: "auto" | "msw" | "http" | "none";
  public httpBasePort: number;
  public httpMaxPortAttempts: number;
  public corsOrigin: string | string[];

  /** Resolved transport kind after selectTransport() runs. */
  private resolvedTransport: "msw" | "http" | "none" = "none";

  /** Populated after transport.start(). Undefined on "none". */
  public baseUrl?: string;
  public port?: number;

  /** Active transport instance; null before initialize() / after unload(). */
  private activeTransport: import("./transports/index.js").Transport | null = null;
```

In the constructor, alongside the existing assignments (after `this.nativeEmbeddingMode = ...`), add:

```typescript
    this.transport = config.transport ?? "auto";
    this.httpBasePort = config.httpBasePort ?? 38883;
    this.httpMaxPortAttempts = config.httpMaxPortAttempts ?? 16;
    this.corsOrigin = config.corsOrigin ?? "*";
```

- [ ] **Step 2: Add getter methods**

Add these public methods near the existing `getActiveBackend()` method:

```typescript
  /** Returns the resolved transport kind (after "auto" resolution). */
  getActiveTransport(): "msw" | "http" | "none" {
    return this.resolvedTransport;
  }

  /** Returns the base URL a host app hands to an OpenAI SDK. */
  getBaseUrl(): string | undefined {
    return this.baseUrl;
  }

  /** Returns the HTTP port bound (http transport only). */
  getPort(): number | undefined {
    return this.port;
  }
```

- [ ] **Step 3: Verify typecheck**

```bash
pnpm --filter @dvai-bridge/core exec tsc --noEmit
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add packages/dvai-bridge-core/src/index.ts
git commit -m "feat(core): add baseUrl/port fields + transport getters"
```

---

### Task 17: Rewire `initialize()` to use the transport abstraction

**Files:**
- Modify: `packages/dvai-bridge-core/src/index.ts`

- [ ] **Step 1: Replace the MSW-setup block in `initialize()` with transport selection + start**

In `packages/dvai-bridge-core/src/index.ts`, find the `initialize()` method. Locate the block that starts with the `isWorkerContext` detection and the `if (!isWorkerContext && this.serviceWorkerUrl) { ... }` MSW setup (around line ~294-343). **Replace that entire block** (from `// Detect Web Worker context` through the `console.log` that says `"[DVAI] Skipping MSW setup..."`) with the transport selection logic:

```typescript
      // Select transport based on env + config
      const { selectTransport, MswTransport, HttpTransport } = await import(
        "./transports/index.js"
      );
      this.resolvedTransport = selectTransport({
        transport: this.transport === "auto" ? undefined : this.transport,
        serviceWorkerUrl: this.serviceWorkerUrl,
      });

      // Warn if mockUrl was explicitly customized under HTTP (will be ignored).
      // The default value is used as the sentinel for "user did not customize".
      if (
        this.resolvedTransport === "http" &&
        this.mockUrl !== "https://api.openai.local/v1/chat/completions"
      ) {
        console.warn(
          "[DVAI] mockUrl config is ignored under transport=\"http\". " +
            "The HTTP server always serves at /v1/*. Use dvai.baseUrl " +
            "to get the exact endpoint.",
        );
      }

      // Warn if serviceWorkerUrl is empty but transport="msw" was forced
      if (
        this.resolvedTransport === "msw" &&
        this.serviceWorkerUrl === "" &&
        this.transport === "msw"
      ) {
        console.warn(
          "[DVAI] serviceWorkerUrl is empty but transport='msw' was requested; MSW will fail to register.",
        );
      }

      // Worker-context informational message
      if (
        this.resolvedTransport === "none" &&
        typeof window === "undefined" &&
        typeof self !== "undefined"
      ) {
        console.log(
          "[DVAI] Running in a Web Worker — no transport started. " +
            "Use dvai.chatCompletion() directly, or register MSW on the main thread.",
        );
      }

      // Construct + start the transport
      if (this.resolvedTransport === "msw") {
        this.activeTransport = new MswTransport({
          mockUrl: this.mockUrl,
          serviceWorkerUrl: this.serviceWorkerUrl,
        });
      } else if (this.resolvedTransport === "http") {
        this.activeTransport = new HttpTransport({
          httpBasePort: this.httpBasePort,
          httpMaxPortAttempts: this.httpMaxPortAttempts,
          corsOrigin: this.corsOrigin,
        });
      } else {
        this.activeTransport = null;
      }

      if (this.activeTransport) {
        const ctx = this.getHandlerContext(onProgress);
        const started = await this.activeTransport.start(ctx);
        this.baseUrl = started.baseUrl;
        this.port = started.port;
      } else {
        this.baseUrl = undefined;
        this.port = undefined;
      }
```

Also delete from the `DVAI` class:
- The `private worker: SetupWorker | null = null;` field (and the `SetupWorker` import if no longer used).
- The entire `buildMswHandlers()` method (moved into `MswTransport`).
- The `getEndpoints()` method (moved into `MswTransport`).
- The `getWorker()` method (no longer exposed — host apps read `dvai.baseUrl` / `dvai.port` instead).

And remove the `setupWorker` / `http as msw_http` / `HttpResponse` imports from `msw/browser` and `msw` at the top of the file — they're all now inside `transports/msw.ts`.

- [ ] **Step 2: Verify typecheck and build**

```bash
pnpm --filter @dvai-bridge/core exec tsc --noEmit
pnpm --filter @dvai-bridge/core build
```

Expected: no errors, build succeeds.

- [ ] **Step 3: Run the full test suite**

```bash
pnpm test -- --run
```

Expected: all existing tests still pass. The `config.test.ts` test that expects `getWorker()` to return `null` will fail — update it:

In `packages/dvai-bridge-core/src/__tests__/config.test.ts`, replace this test:

```typescript
  it("should return null engine before initialization", () => {
    const dvai = new DVAI();
    expect(dvai.getEngine()).toBeNull();
    expect(dvai.getWorker()).toBeNull();
  });
```

With:

```typescript
  it("should return null engine before initialization", () => {
    const dvai = new DVAI();
    expect(dvai.getEngine()).toBeNull();
    expect(dvai.getBaseUrl()).toBeUndefined();
    expect(dvai.getPort()).toBeUndefined();
    expect(dvai.getActiveTransport()).toBe("none");
  });
```

Re-run tests:

```bash
pnpm test -- --run
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add packages/dvai-bridge-core/src/index.ts packages/dvai-bridge-core/src/__tests__/config.test.ts
git commit -m "refactor(core): rewire initialize() through transport abstraction"
```

---

### Task 18: Update `unload()` + transport equivalence test

**Files:**
- Modify: `packages/dvai-bridge-core/src/index.ts`
- Create: `packages/dvai-bridge-core/src/__tests__/transport-fixtures.ts`
- Create: `packages/dvai-bridge-core/src/__tests__/transport-equivalence.msw.test.ts`
- Create: `packages/dvai-bridge-core/src/__tests__/transport-equivalence.http.test.ts`

- [ ] **Step 1: Update `unload()` on `DVAI`**

In `packages/dvai-bridge-core/src/index.ts`, replace the body of `unload()`:

```typescript
  async unload(): Promise<void> {
    if (this.backendInstance) {
      await this.backendInstance.unload();
      this.backendInstance = null;
    }
    if (this.activeTransport) {
      await this.activeTransport.stop();
      this.activeTransport = null;
    }
    this.baseUrl = undefined;
    this.port = undefined;
    this.isReady = false;
    this.recoveryAttempts = 0;
    console.log("[DVAI] Unloaded model and transport.");
  }
```

- [ ] **Step 2: Create shared fixtures**

Create `packages/dvai-bridge-core/src/__tests__/transport-fixtures.ts`:

```typescript
import type { BackendInterface, HandlerContext } from "../handlers/context";

export const CANNED_CHAT_COMPLETION = {
  id: "chatcmpl-fixed",
  object: "chat.completion",
  created: 1700000000,
  model: "test-model",
  choices: [
    {
      index: 0,
      message: { role: "assistant", content: "canned" },
      finish_reason: "stop",
    },
  ],
  usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
};

export function makeStreamBackend(): BackendInterface {
  return {
    chatCompletion: async () => CANNED_CHAT_COMPLETION,
    createStreamingResponse: () => {
      const encoder = new TextEncoder();
      return new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(
            encoder.encode(
              `data: ${JSON.stringify({ id: "chatcmpl-fixed", choices: [{ delta: { content: "canned" }, index: 0 }] })}\n\n`,
            ),
          );
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        },
      });
    },
    embedding: async (inputs) => {
      const arr = Array.isArray(inputs) ? inputs : [inputs];
      return arr.map((_, i) => [i * 0.1, i * 0.2, i * 0.3]);
    },
  };
}

export function makeCtx(
  backend: BackendInterface = makeStreamBackend(),
  overrides: Partial<HandlerContext> = {},
): HandlerContext {
  return {
    backend,
    resolvedBackend: "transformers",
    modelId: "test-model",
    ...overrides,
  };
}

export const CHAT_REQUEST = {
  model: "test-model",
  messages: [{ role: "user", content: "hi" }],
};

export const COMPLETION_REQUEST = {
  model: "test-model",
  prompt: "hi",
};

export const EMBEDDING_REQUEST = {
  model: "test-model",
  input: ["hello", "world"],
};
```

- [ ] **Step 3: Create the MSW-side equivalence test**

Create `packages/dvai-bridge-core/src/__tests__/transport-equivalence.msw.test.ts`:

```typescript
// @vitest-environment happy-dom
import { describe, it, expect } from "vitest";
import {
  makeCtx,
  CHAT_REQUEST,
  COMPLETION_REQUEST,
  EMBEDDING_REQUEST,
  CANNED_CHAT_COMPLETION,
} from "./transport-fixtures";

// happy-dom provides navigator.serviceWorker, but MSW's setupWorker does an
// actual registration that needs a mockServiceWorker.js. Rather than register,
// we invoke the handlers directly — the same four pure functions the MSW
// transport would wire up. This is what MSW would produce.
describe("MSW-path equivalence (via direct handler invocation)", () => {
  it("POST /v1/chat/completions returns the canned body", async () => {
    const { handleChatCompletion } = await import("../handlers/chat");
    const res = await handleChatCompletion(CHAT_REQUEST, makeCtx());
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual(CANNED_CHAT_COMPLETION);
  });

  it("POST /v1/completions returns the legacy-shaped body", async () => {
    const { handleCompletion } = await import("../handlers/completions");
    const res = await handleCompletion(COMPLETION_REQUEST, makeCtx());
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.object).toBe("text_completion");
    expect(body.choices[0].text).toBe("canned");
  });

  it("POST /v1/embeddings returns OpenAI-shaped embeddings", async () => {
    const { handleEmbeddings } = await import("../handlers/embeddings");
    const res = await handleEmbeddings(EMBEDDING_REQUEST, makeCtx());
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.object).toBe("list");
    expect(body.data).toHaveLength(2);
  });

  it("GET /v1/models returns the list with context model", async () => {
    const { handleModels } = await import("../handlers/models");
    const res = await handleModels(makeCtx());
    const body = await res.json();
    expect(body.data[0].id).toBe("test-model");
  });
});
```

- [ ] **Step 4: Create the HTTP-side equivalence test**

Create `packages/dvai-bridge-core/src/__tests__/transport-equivalence.http.test.ts`:

```typescript
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { HttpTransport } from "../transports/http";
import {
  makeCtx,
  CHAT_REQUEST,
  COMPLETION_REQUEST,
  EMBEDDING_REQUEST,
  CANNED_CHAT_COMPLETION,
} from "./transport-fixtures";

// Dedicated test port range — don't collide with dev-running DVAI.
const TEST_PORT = 39500;

describe("HTTP transport end-to-end", () => {
  let transport: HttpTransport;
  let baseUrl: string;

  beforeAll(async () => {
    transport = new HttpTransport({
      httpBasePort: TEST_PORT,
      httpMaxPortAttempts: 4,
      corsOrigin: "*",
    });
    const result = await transport.start(makeCtx());
    baseUrl = result.baseUrl;
  });

  afterAll(async () => {
    await transport.stop();
  });

  it("POST /v1/chat/completions returns the canned body", async () => {
    const res = await fetch(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(CHAT_REQUEST),
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual(CANNED_CHAT_COMPLETION);
  });

  it("POST /v1/chat/completions streams SSE on stream=true", async () => {
    const res = await fetch(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...CHAT_REQUEST, stream: true }),
    });
    expect(res.headers.get("content-type")).toMatch(/text\/event-stream/);
    const text = await res.text();
    expect(text).toContain("data: [DONE]");
  });

  it("POST /v1/completions returns legacy-shaped body", async () => {
    const res = await fetch(`${baseUrl}/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(COMPLETION_REQUEST),
    });
    const body = await res.json();
    expect(body.object).toBe("text_completion");
  });

  it("POST /v1/embeddings returns OpenAI-shaped embeddings", async () => {
    const res = await fetch(`${baseUrl}/embeddings`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(EMBEDDING_REQUEST),
    });
    const body = await res.json();
    expect(body.object).toBe("list");
    expect(body.data).toHaveLength(2);
  });

  it("GET /v1/models returns the list", async () => {
    const res = await fetch(`${baseUrl}/models`);
    const body = await res.json();
    expect(body.data[0].id).toBe("test-model");
  });

  it("unknown route returns 404", async () => {
    const res = await fetch(`${baseUrl}/unknown`);
    expect(res.status).toBe(404);
  });

  it("OPTIONS preflight returns 204 with PNA headers", async () => {
    const res = await fetch(`${baseUrl}/chat/completions`, {
      method: "OPTIONS",
      headers: {
        "Origin": "https://example.com",
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Private-Network": "true",
      },
    });
    expect(res.status).toBe(204);
    expect(res.headers.get("access-control-allow-private-network")).toBe("true");
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
    expect(res.headers.get("access-control-allow-methods")).toContain("POST");
  });
});
```

- [ ] **Step 5: Install happy-dom as a dev dep**

```bash
pnpm add -D -w happy-dom
```

- [ ] **Step 6: Run all tests**

```bash
pnpm test -- --run
```

Expected: all tests pass, including the new equivalence tests.

- [ ] **Step 7: Commit**

```bash
git add packages/dvai-bridge-core/src/index.ts packages/dvai-bridge-core/src/__tests__/ package.json pnpm-lock.yaml
git commit -m "test(transports): add transport equivalence suite (msw + http)"
```

---

## Phase E — Build verification + version bump

### Task 19: Version bump + CHANGELOG.md

**Files:**
- Modify: `package.json`
- Create: `CHANGELOG.md`

- [ ] **Step 1: Bump root version**

Edit `package.json` (root), change:

```json
  "version": "1.5.2",
```

to:

```json
  "version": "1.6.0",
```

- [ ] **Step 2: Run the version sync**

```bash
node scripts/sync-versions.js
```

Expected: "Syncing version 1.6.0 to all packages..." with one line per package.

- [ ] **Step 3: Create `CHANGELOG.md` at repo root**

```markdown
# Changelog

All notable changes to this project are documented here. This project
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.6.0] — 2026-MM-DD

### Added
- `transport` config option: `"auto" | "msw" | "http" | "none"`.
- HTTP transport for Node and Electron main process (base port 38883,
  +1 fallback up to 16 attempts on `EADDRINUSE`).
- `dvai.baseUrl` and `dvai.port` fields.
- `dvai.getBaseUrl()`, `dvai.getPort()`, `dvai.getActiveTransport()` methods.
- New transport-agnostic handler module under `src/handlers/`.
- CORS + Private Network Access headers on HTTP transport responses
  (enables HTTPS pages calling loopback without Chrome/Edge PNA blocks).
- `BASE_PORT` and `MAX_PORT_ATTEMPTS` exported constants from
  `@dvai-bridge/core`.
- `httpBasePort`, `httpMaxPortAttempts`, `corsOrigin` config options.
- Root-level `examples/` directory (moved out of the package dir).
- `files` allowlist on all package `package.json` files — prevents
  `src/`, `example/`, and test files from shipping to npm.

### Changed
- `mockUrl` is now MSW-specific. Under HTTP transport, it is ignored
  with a one-time console warning. Read `dvai.baseUrl` for the real URL.
- `DVAI` in Node now auto-starts a real HTTP server on `initialize()`
  (previously crashed trying to register MSW without
  `navigator.serviceWorker`).
- Internal `buildMswHandlers` refactored into pure handler functions
  plus a thin MSW transport adapter.

### Removed
- `packages/dvai-bridge-core/example/langchain-node-example.js` standalone
  snippet (replaced by the runnable `examples/node-langchain/` project).
- `DVAI.getWorker()` method (the MSW worker is now an implementation
  detail of `MswTransport`; use `dvai.getBaseUrl()` instead).

### Fixed
- `new DVAI()` in plain Node no longer crashes — auto-resolves to the
  new HTTP transport.

### Migration guide: 1.5.x → 1.6.0

**Browser consumers (React / Vanilla):** no action required.
`new DVAI({})` continues to use MSW in browsers with identical behavior.

**Node / Electron consumers:** `DVAI` now auto-boots an HTTP server at
`http://127.0.0.1:38883/v1`. Read `dvai.baseUrl` and pass it to your
OpenAI SDK:

```javascript
const dvai = new DVAI({ backend: "transformers" });
await dvai.initialize();
// dvai.baseUrl === "http://127.0.0.1:38883/v1" (or 38884, 38885, ...)

const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
```

If you want the old direct-inference-only behavior (no transport),
pass `transport: "none"` explicitly, or keep using `serviceWorkerUrl: ""`.

**Custom `mockUrl` + HTTP:** `mockUrl` is ignored under HTTP transport.
If you need a specific URL shape, stay on MSW (`transport: "msw"`,
browser only), or read `dvai.baseUrl` at runtime.

**Removed `getWorker()`:** if you depended on direct access to the MSW
worker instance, that's no longer exposed. Use `dvai.baseUrl` for the
endpoint URL, or `dvai.getActiveTransport()` to check which transport
is active.
```

(Fill in the real release date when the tag is cut.)

- [ ] **Step 4: Commit**

```bash
git add package.json packages/*/package.json CHANGELOG.md
git commit -m "chore: bump to 1.6.0 + add CHANGELOG.md"
```

---

## Phase F — Docs

### Task 20: Create `docs/guide/transports.md`

**Files:**
- Create: `docs/guide/transports.md`

- [ ] **Step 1: Write the transports guide**

```markdown
# Transports

`dvai-bridge` exposes a single OpenAI-compatible HTTP surface on every
platform — the transport under that surface is selected automatically
based on the runtime environment.

## How selection works

When you call `dvai.initialize()`, the library picks one of three
transports:

| Transport | When it's used | What it does |
|---|---|---|
| `msw` | Browser main thread | Registers an MSW service worker that intercepts fetch calls to an OpenAI-shaped URL. No actual server. |
| `http` | Node / Electron main process | Boots a real `http.createServer` on `127.0.0.1` starting at port `38883`, serves `/v1/*` endpoints. |
| `none` | Web Workers, Service Workers, or when you opt out | No transport started. Use `dvai.chatCompletion()` directly. |

You read the endpoint via `dvai.baseUrl`:

- MSW path: `"https://api.openai.local/v1"` (or whatever you set via `mockUrl`).
- HTTP path: `"http://127.0.0.1:38883/v1"` (or the fallback port if 38883 was busy).

## Port fallback

On HTTP, if the base port is taken, `dvai-bridge` retries `38884`, `38885`,
... up to 16 attempts. If all are in use, `initialize()` throws with an
actionable error listing the tried range.

Override the base port or attempts limit:

```ts
new DVAI({ httpBasePort: 40000, httpMaxPortAttempts: 4 });
```

## Overriding the transport

Usually you don't need to. If you do:

```ts
new DVAI({ transport: "msw" });   // force MSW (browser only)
new DVAI({ transport: "http" });  // force HTTP (Node only)
new DVAI({ transport: "none" });  // no transport; direct inference only
```

## CORS and Private Network Access

The HTTP transport emits CORS + PNA headers on every response so
HTTPS pages can call loopback without being blocked by Chrome's
Private Network Access enforcement. Configure the allowed origin:

```ts
new DVAI({ corsOrigin: "*" });                        // default
new DVAI({ corsOrigin: "https://app.example.com" });  // exact origin
new DVAI({ corsOrigin: ["https://a.com", "https://b.com"] }); // allowlist
```

## Mobile (Android NSC)

Android 9+ blocks cleartext HTTP by default. For Capacitor / React
Native / native apps using the HTTP transport on loopback, add a
network-security-config allowing cleartext for `127.0.0.1`:

```xml
<network-security-config>
  <domain-config cleartextTrafficPermitted="true">
    <domain includeSubdomains="true">localhost</domain>
    <domain>127.0.0.1</domain>
  </domain-config>
</network-security-config>
```

In later phases, the Capacitor plugin and Android AAR will inject this
automatically via their Gradle scripts. iOS has no equivalent step —
ATS exempts loopback by default.
```

- [ ] **Step 2: Commit**

```bash
git add docs/guide/transports.md
git commit -m "docs: add transports guide"
```

---

### Task 21: Update existing guide docs

**Files:**
- Modify: `docs/guide/introduction.md`
- Modify: `docs/guide/getting-started.md`
- Modify: `docs/reference/api.md`

- [ ] **Step 1: Update `docs/guide/introduction.md`**

Add this paragraph at the end of the "Hybrid Selection" section:

```markdown
## Transport Auto-Detection

`DVAI` now auto-selects the right transport for the runtime: MSW in
browsers, a real HTTP server in Node / Electron main, no transport in
Web Workers. Host applications simply read `dvai.baseUrl` and hand it
to any OpenAI SDK — the rest is identical across platforms. See the
[Transports guide](/guide/transports) for details.
```

- [ ] **Step 2: Update `docs/guide/getting-started.md`**

Append a new section at the end:

```markdown
## Node quick-start

`dvai-bridge` works in plain Node — the library auto-starts an HTTP
server on `127.0.0.1:38883` (with port fallback).

```javascript
import { DVAI } from "@dvai-bridge/core";
import OpenAI from "openai";

const dvai = new DVAI({ backend: "transformers" });
await dvai.initialize();
console.log(dvai.baseUrl); // e.g. "http://127.0.0.1:38883/v1"

const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
const r = await openai.chat.completions.create({
  model: dvai.transformersModelId,
  messages: [{ role: "user", content: "Hello!" }],
});
console.log(r.choices[0].message.content);
```

Point any OpenAI-compatible SDK (Node, .NET, Python, etc.) at
`dvai.baseUrl` — all talk to the same local endpoint.
```

- [ ] **Step 3: Update `docs/reference/api.md`**

Add these entries to the config reference table (alphabetize if the
existing table is alphabetized; otherwise append):

```markdown
| `transport`            | `"auto" \| "msw" \| "http" \| "none"` | `"auto"` | Transport selection. `"auto"` picks MSW in browser, HTTP in Node. |
| `httpBasePort`         | `number`   | `38883`  | HTTP transport base port (retries +1 up to 16 times).              |
| `httpMaxPortAttempts`  | `number`   | `16`     | Max HTTP port fallback attempts before throwing.                    |
| `corsOrigin`           | `string \| string[]`  | `"*"`    | HTTP `Access-Control-Allow-Origin` value or allowlist.              |
```

Add these entries to the class-member reference section (same location as the existing `getEngine()` entry):

```markdown
### Instance fields

- `dvai.baseUrl?: string` — URL to hand to OpenAI SDKs. `undefined` when `transport="none"`.
- `dvai.port?: number` — Bound HTTP port (HTTP transport only).

### Methods

- `dvai.getBaseUrl(): string | undefined` — Method form of `dvai.baseUrl`.
- `dvai.getPort(): number | undefined` — Method form of `dvai.port`.
- `dvai.getActiveTransport(): "msw" | "http" | "none"` — Resolved transport after `initialize()`.
```

Remove any reference to `dvai.getWorker()` in this file (the method no longer exists).

- [ ] **Step 4: Build the docs**

```bash
pnpm --filter docs build
```

Expected: success.

- [ ] **Step 5: Commit**

```bash
git add docs/guide/introduction.md docs/guide/getting-started.md docs/reference/api.md
git commit -m "docs: document transports, baseUrl/port, and new config fields"
```

---

### Task 22: Migration guide + README

**Files:**
- Create: `docs/migration/v1.5-to-v1.6.md`
- Modify: `README.md`

- [ ] **Step 1: Create `docs/migration/v1.5-to-v1.6.md`**

```markdown
# Migrating from 1.5.x to 1.6.0

**TL;DR:** Browser consumers need no changes. Node consumers now get a
real HTTP server automatically instead of a crash.

## What changed

`@dvai-bridge/core` 1.6.0 adds a real HTTP server transport for Node
and Electron main process. Browser behavior (MSW interception) is
unchanged. See [`CHANGELOG.md`](../../CHANGELOG.md) for the full list.

## Browser consumers (React / Vanilla)

No action required. `new DVAI({})` continues to use MSW in browsers
with identical behavior. `dvai.mockUrl` and all existing config
continue to work.

If you want to read the endpoint in a platform-agnostic way, use the
new `dvai.baseUrl` field (set after `initialize()`):

```ts
const dvai = new DVAI({});
await dvai.initialize();
const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
```

## Node / Electron consumers

Previously, `new DVAI({})` in Node crashed because MSW requires
`navigator.serviceWorker`. Now it auto-starts an HTTP server on
`127.0.0.1:38883` (with +1 port fallback up to 16 attempts).

```ts
const dvai = new DVAI({ backend: "transformers" });
await dvai.initialize();
// dvai.baseUrl === "http://127.0.0.1:38883/v1"

const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
```

To keep the old "direct inference only" behavior (no transport):

```ts
new DVAI({ transport: "none" });
// or the still-supported BC form:
new DVAI({ serviceWorkerUrl: "" });
```

## `mockUrl` under HTTP transport

`mockUrl` is ignored when the transport is HTTP. A one-time console
warning fires on `initialize()` if you set a custom `mockUrl` while
HTTP is active. Use `dvai.baseUrl` to get the real URL at runtime.

## Removed: `DVAI.getWorker()`

The MSW worker is now an implementation detail of the `MswTransport`
class and is not exposed directly. If you relied on this method:

- To get the endpoint URL: use `dvai.baseUrl` or `dvai.getBaseUrl()`.
- To check which transport is active: use `dvai.getActiveTransport()`.
- To stop intercepting: use `dvai.unload()`.

## New config options

- `transport?: "auto" | "msw" | "http" | "none"` — transport selection.
- `httpBasePort?: number` — HTTP base port (default `38883`).
- `httpMaxPortAttempts?: number` — max fallback attempts (default `16`).
- `corsOrigin?: string | string[]` — CORS origin config for HTTP.

See [`docs/guide/transports.md`](../guide/transports.md) for a deep dive.
```

- [ ] **Step 2: Update `README.md`**

In `README.md` at the repo root, replace the "Key Features" bullets list (around line 11-22) with an updated list including the new transport capabilities. Add this bullet near the top:

```markdown
- **Platform-Agnostic Transport**: Auto-starts an MSW service worker in browsers or a real HTTP server (127.0.0.1:38883) in Node/Electron. Host apps just read `dvai.baseUrl` and pass it to any OpenAI SDK.
```

Also update the config reference table (around line 253-269) — add rows for the new fields (same content as `docs/reference/api.md` additions in Task 21).

Also add a new "Node Usage" section between the "Vanilla JS / CDN" and "Direct Inference" sections:

```markdown
### Node / Electron Usage

```javascript
import { DVAI } from "@dvai-bridge/core";
import OpenAI from "openai";

const dvai = new DVAI({ backend: "transformers" });
await dvai.initialize();
console.log(`DVAI live at ${dvai.baseUrl}`); // http://127.0.0.1:38883/v1

const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
const r = await openai.chat.completions.create({
  model: dvai.transformersModelId,
  messages: [{ role: "user", content: "Hello!" }],
});
console.log(r.choices[0].message.content);
```
```

- [ ] **Step 3: Commit**

```bash
git add docs/migration/v1.5-to-v1.6.md README.md
git commit -m "docs: add v1.5→v1.6 migration guide and update README"
```

---

### Task 23: Final verification

- [ ] **Step 1: Run the full test suite**

```bash
pnpm test -- --run
```

Expected: all tests pass.

- [ ] **Step 2: Build every package**

```bash
pnpm -r run build
```

Expected: all packages build successfully.

- [ ] **Step 3: Verify tarball contents**

```bash
cd packages/dvai-bridge-core && pnpm pack --dry-run
cd ../dvai-bridge-react   && pnpm pack --dry-run
cd ../dvai-bridge-vanilla && pnpm pack --dry-run
```

Expected: only `dist/`, `bin/` (core only), `package.json`, `README.md`, `LICENSE` in each tarball. No `src/`, no `examples/`, no `__tests__/`.

- [ ] **Step 4: Build the VitePress docs site**

```bash
pnpm --filter docs build
```

Expected: success. No broken links to the removed `getWorker` or the moved examples.

- [ ] **Step 5: Run the node-langchain example end-to-end**

```bash
pnpm --filter node-langchain start
```

Expected: model downloads on first run, then prints a streamed answer about the capital of France. Example exits cleanly.

- [ ] **Step 6: Commit any final polish**

If any step required a small fix, commit it:

```bash
git add .
git commit -m "chore: final polish from Phase 0 verification"
```

- [ ] **Step 7: Log the version + verify**

```bash
cat package.json | grep version
cat packages/dvai-bridge-core/package.json | grep version
cat packages/dvai-bridge-react/package.json | grep version
cat packages/dvai-bridge-vanilla/package.json | grep version
```

Expected: all four report `"version": "1.6.0"`.

---

## Self-review notes

Spec coverage check:
- Spec §2 goals (1-6): all covered by Tasks 4-18 (handlers + transport + equivalence test), Tasks 1-3 (restructure), Task 19 (version bump + changelog).
- Spec §5 restructure: Tasks 1-3.
- Spec §6 handler module: Tasks 4-9.
- Spec §7 transport layer: Tasks 10-14.
- Spec §8 public API: Tasks 15-17.
- Spec §9 testing strategy: Tasks 5-8 (handler tests), Task 10 (port-fallback), Task 18 (equivalence).
- Spec §10 operational rollout: Tasks 19-23.
- Spec §7.4 route table (OPTIONS preflight, 404 for unknown): covered in Task 13 impl + Task 18 test.
- Spec §8.7 `serviceWorkerUrl: ""` BC: covered by Task 14 selection tests.
- Spec §7.7 mockUrl-under-HTTP warning: covered by Task 17 impl.

Type consistency check: `HandlerContext`, `BackendInterface`, `Transport`, `TransportStartResult`, `HttpTransportOptions`, `MswTransportOptions` referenced consistently across tasks.
