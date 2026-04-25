import { describe, it, expect, vi, beforeEach } from "vitest";

const mockNativePlugin = {
  start: vi.fn(async () => ({ baseUrl: "http://127.0.0.1:38883/v1", port: 38883, backend: "llama", modelId: "test" })),
  stop: vi.fn(async () => undefined),
  status: vi.fn(async () => ({ running: true })),
};

vi.mock("@capacitor/core", () => ({
  registerPlugin: vi.fn((_name: string) => mockNativePlugin),
}));

describe("backend dispatch", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();
  });

  it("routes backend:'llama' to DVAIBridgeLlama plugin", async () => {
    const { registerPlugin } = await import("@capacitor/core");
    const { dispatch } = await import("../dispatch");
    await dispatch.start({ backend: "llama", modelPath: "/m.gguf" });
    expect(registerPlugin).toHaveBeenCalledWith("DVAIBridgeLlama");
  });

  it("routes backend:'foundation' to DVAIBridgeFoundation plugin", async () => {
    const { registerPlugin } = await import("@capacitor/core");
    const { dispatch } = await import("../dispatch");
    await dispatch.start({ backend: "foundation" });
    expect(registerPlugin).toHaveBeenCalledWith("DVAIBridgeFoundation");
  });

  it("routes backend:'mediapipe' to DVAIBridgeMediaPipe plugin", async () => {
    const { registerPlugin } = await import("@capacitor/core");
    const { dispatch } = await import("../dispatch");
    await dispatch.start({ backend: "mediapipe", modelPath: "/m.task" });
    expect(registerPlugin).toHaveBeenCalledWith("DVAIBridgeMediaPipe");
  });

  it("after start(), stop() routes to the active plugin", async () => {
    const { dispatch } = await import("../dispatch");
    await dispatch.start({ backend: "llama", modelPath: "/m.gguf" });
    await dispatch.stop();
    expect(mockNativePlugin.stop).toHaveBeenCalled();
  });
});

describe("DVAIBridge public API", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();
  });

  it("DVAIBridge.start delegates to dispatch", async () => {
    const { DVAIBridge } = await import("../index");
    const result = await DVAIBridge.start({ backend: "llama", modelPath: "/m.gguf" });
    expect(result).toMatchObject({ port: 38883, backend: "llama" });
  });

  it("DVAIBridge.status returns running:false before start", async () => {
    const { DVAIBridge } = await import("../index");
    const status = await DVAIBridge.status();
    expect(status.running).toBe(false);
  });

  it("DVAIBridge.stop is idempotent before start", async () => {
    const { DVAIBridge } = await import("../index");
    await expect(DVAIBridge.stop()).resolves.not.toThrow();
  });
});
