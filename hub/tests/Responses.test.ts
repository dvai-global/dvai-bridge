/**
 * Tests for the Hub's 503 error-response builders.
 *
 * Both builders mirror the rendezvous-side core lib pattern in
 * `packages/dvai-bridge-core/src/offload/error.ts`:
 *   - HTTP 503
 *   - `Retry-After: 30` header
 *   - OpenAI-error-shaped body with a typed `error.type` field
 *
 * The Retry-After header was added in the v3.2.x patch covering the
 * UK patent claim 18 alignment — these tests prevent regression on
 * that contract.
 */

import { describe, it, expect } from "vitest";
import {
  buildNoCapableDeviceResponse,
  buildEngineAdapterNotFoundResponse,
  HUB_503_RETRY_AFTER_SECONDS,
} from "../peer-mode/responses.js";

describe("responses — buildNoCapableDeviceResponse", () => {
  it("returns HTTP 503", () => {
    const res = buildNoCapableDeviceResponse("Llama-3.2-3B-Q4_K_M", "type_mismatch");
    expect(res.status).toBe(503);
  });

  it("sets Retry-After: 30 header (matching core lib offload/error.ts)", () => {
    const res = buildNoCapableDeviceResponse("Llama-3.2-3B-Q4_K_M", "type_mismatch");
    expect(res.headers.get("Retry-After")).toBe("30");
    expect(HUB_503_RETRY_AFTER_SECONDS).toBe(30);
  });

  it("emits OpenAI-error-shaped body with type=no_capable_device", async () => {
    const res = buildNoCapableDeviceResponse(
      "Llama-3.2-3B-Code-Q4_K_M",
      "type_mismatch",
    );
    const json = (await res.json()) as { error: { type: string; code: number; message: string } };
    expect(json.error.type).toBe("no_capable_device");
    expect(json.error.code).toBe(503);
    expect(json.error.message).toContain("Llama-3.2-3B-Code-Q4_K_M");
    expect(json.error.message).toContain("type_mismatch");
  });

  it("omits the detail field when caller passes undefined", async () => {
    const res = buildNoCapableDeviceResponse("foo", "reason");
    const json = (await res.json()) as { error: Record<string, unknown> };
    expect(json.error.detail).toBeUndefined();
    expect("detail" in json.error).toBe(false);
  });

  it("includes the detail field when caller provides one", async () => {
    const res = buildNoCapableDeviceResponse("foo", "reason", { tried: 3 });
    const json = (await res.json()) as { error: { detail?: { tried: number } } };
    expect(json.error.detail).toEqual({ tried: 3 });
  });
});

describe("responses — buildEngineAdapterNotFoundResponse", () => {
  it("returns HTTP 503", () => {
    const res = buildEngineAdapterNotFoundResponse("ollama");
    expect(res.status).toBe(503);
  });

  it("sets Retry-After: 30 header (matching core lib offload/error.ts)", () => {
    const res = buildEngineAdapterNotFoundResponse("ollama");
    expect(res.headers.get("Retry-After")).toBe("30");
  });

  it("emits OpenAI-error-shaped body with type=engine_adapter_not_found", async () => {
    const res = buildEngineAdapterNotFoundResponse("lm-studio");
    const json = (await res.json()) as { error: { type: string; code: number; message: string } };
    expect(json.error.type).toBe("engine_adapter_not_found");
    expect(json.error.code).toBe(503);
    expect(json.error.message).toContain("lm-studio");
  });
});
