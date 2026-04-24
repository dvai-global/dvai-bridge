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
