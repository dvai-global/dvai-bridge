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
