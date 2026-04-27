/**
 * Unit tests for the `@dvai-bridge/react-native` TS facade.
 *
 * The native TurboModule is mocked via `jest.setup.js` (see
 * `react-native.__mockNativeModule`). Each test overrides whichever
 * methods it needs.
 */

import { DVAIBridge } from "../DVAIBridge";
import { DVAIBridgeError } from "../errors";
import { BackendKind } from "../types";

const RN = require("react-native");

beforeEach(() => {
  RN.__resetListeners();
  RN.__mockNativeModule.startBridge.mockReset();
  RN.__mockNativeModule.stopBridge.mockReset();
  RN.__mockNativeModule.status.mockReset();
  RN.__mockNativeModule.downloadModel.mockReset();
  RN.__mockNativeModule.addListener.mockReset();
  RN.__mockNativeModule.removeListeners.mockReset();
  // Default to iOS unless a test overrides.
  RN.Platform.OS = "ios";
});

describe("DVAIBridge.start — platform validation", () => {
  it("rejects iOS-only backend on Android with backendUnavailable", async () => {
    RN.Platform.OS = "android";
    await expect(
      DVAIBridge.start({ backend: BackendKind.Foundation }),
    ).rejects.toMatchObject({
      kind: "backendUnavailable",
    });
    // Native module must NOT be called when TS-side validation rejects.
    expect(RN.__mockNativeModule.startBridge).not.toHaveBeenCalled();
  });

  it("rejects Android-only backend on iOS with backendUnavailable", async () => {
    RN.Platform.OS = "ios";
    await expect(
      DVAIBridge.start({ backend: BackendKind.MediaPipe }),
    ).rejects.toBeInstanceOf(DVAIBridgeError);
    await expect(
      DVAIBridge.start({ backend: BackendKind.LiteRT }),
    ).rejects.toMatchObject({ kind: "backendUnavailable" });
    expect(RN.__mockNativeModule.startBridge).not.toHaveBeenCalled();
  });
});

describe("DVAIBridge.start — happy path", () => {
  it("forwards opts to the TurboModule and returns the BoundServer shape", async () => {
    RN.Platform.OS = "ios";
    RN.__mockNativeModule.startBridge.mockResolvedValueOnce({
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "llama",
      modelId: "Llama-3.2-1B-Instruct.Q4_K_M",
    });

    const server = await DVAIBridge.start({
      backend: BackendKind.Llama,
      modelPath: "/tmp/model.gguf",
      contextSize: 4096,
    });

    expect(server).toEqual({
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "llama",
      modelId: "Llama-3.2-1B-Instruct.Q4_K_M",
    });
    expect(RN.__mockNativeModule.startBridge).toHaveBeenCalledTimes(1);
    expect(RN.__mockNativeModule.startBridge).toHaveBeenCalledWith({
      backend: "llama",
      modelPath: "/tmp/model.gguf",
      contextSize: 4096,
    });
  });

  it("rewraps native errors as DVAIBridgeError with the kind preserved", async () => {
    RN.Platform.OS = "ios";
    const nativeErr = Object.assign(new Error("Model file not found"), {
      code: "modelLoadFailed",
    });
    RN.__mockNativeModule.startBridge.mockRejectedValueOnce(nativeErr);

    await expect(
      DVAIBridge.start({ backend: BackendKind.Llama, modelPath: "/nope.gguf" }),
    ).rejects.toMatchObject({
      kind: "modelLoadFailed",
      message: "Model file not found",
    });
  });
});

describe("DVAIBridge.stop", () => {
  it("calls the TurboModule and resolves to undefined", async () => {
    RN.__mockNativeModule.stopBridge.mockResolvedValueOnce(undefined);
    await expect(DVAIBridge.stop()).resolves.toBeUndefined();
    expect(RN.__mockNativeModule.stopBridge).toHaveBeenCalledTimes(1);
  });
});

describe("DVAIBridge.addProgressListener", () => {
  it("returns a removable subscription that gates further events", () => {
    const events: unknown[] = [];
    const sub = DVAIBridge.addProgressListener((event) => {
      events.push(event);
    });

    RN.__emit("DVAIBridgeProgress", { kind: "progress", phase: "start", percent: 50 });
    expect(events).toHaveLength(1);

    sub.remove();

    RN.__emit("DVAIBridgeProgress", { kind: "completed", phase: "start" });
    expect(events).toHaveLength(1);
  });
});
