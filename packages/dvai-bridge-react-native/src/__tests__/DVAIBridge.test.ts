/**
 * Unit tests for the `@dvai-bridge/react-native` TS facade.
 *
 * The native TurboModule is mocked via `jest.setup.js` (see
 * `react-native.__mockNativeModule`). Each test overrides whichever
 * methods it needs.
 */

import { vi } from 'vitest';
vi.mock('react-native', () => {
  const listeners = new Map();
  const mockNativeModule = {
    startBridge: vi.fn(),
    stopBridge: vi.fn(),
    status: vi.fn(),
    downloadModel: vi.fn(),
    respondToPairing: vi.fn(),
    addListener: vi.fn(),
    removeListeners: vi.fn(),
    assessHardware: vi.fn(),
  };

  return {
    Platform: {
      OS: "ios",
      select: (specifics: any) => specifics.ios ?? specifics.default,
    },
    NativeEventEmitter: class {
      addListener(eventName: string, listener: any) {
        const arr = listeners.get(eventName) ?? [];
        arr.push(listener);
        listeners.set(eventName, arr);
        return {
          remove: () => {
            const current = listeners.get(eventName) ?? [];
            listeners.set(
              eventName,
              current.filter((fn: any) => fn !== listener),
            );
          },
        };
      }
      removeAllListeners(eventName: string) {
        listeners.delete(eventName);
      }
      emit(eventName: string, payload: any) {
        (listeners.get(eventName) ?? []).forEach((fn: any) => fn(payload));
      }
    },
    NativeModules: {
      DVAIBridge: mockNativeModule,
    },
    TurboModuleRegistry: {
      getEnforcing: vi.fn(() => mockNativeModule),
      get: vi.fn(() => mockNativeModule),
    },
    __mockNativeModule: mockNativeModule,
    __emit: (eventName: string, payload: any) => {
      (listeners.get(eventName) ?? []).forEach((fn: any) => fn(payload));
    },
    __resetListeners: () => listeners.clear(),
  };
});

import { DVAIBridge } from "../DVAIBridge";
import { DVAIBridgeError } from "../errors";
import { BackendKind } from "../types";
import * as RN from "react-native";

beforeEach(() => {
  RN.__resetListeners();
  RN.__mockNativeModule.startBridge.mockReset();
  RN.__mockNativeModule.stopBridge.mockReset();
  RN.__mockNativeModule.status.mockReset();
  RN.__mockNativeModule.downloadModel.mockReset();
  RN.__mockNativeModule.respondToPairing.mockReset();
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

describe("DVAIBridge.start — offload config", () => {
  it("forwards the offload field through to the TurboModule untouched", async () => {
    RN.Platform.OS = "ios";
    RN.__mockNativeModule.startBridge.mockResolvedValueOnce({
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "auto",
      modelId: "Llama-3.2-1B-Instruct.Q4_K_M",
    });

    await DVAIBridge.start({
      backend: BackendKind.Auto,
      modelPath: "/tmp/m.gguf",
      offload: {
        enabled: true,
        discoverLAN: true,
        minLocalCapability: 12,
        rendezvousUrl: "wss://rendezvous.myapp.com",
        knownPeers: [
          {
            deviceId: "peer-1",
            deviceName: "Studio Mac",
            dvaiVersion: "3.0.0",
            baseUrl: "http://192.168.1.42:38883/v1",
            loadedModels: ["Llama-3.2-1B-Instruct.Q4_K_M"],
            capability: { "Llama-3.2-1B-Instruct.Q4_K_M": 32 },
            via: "static",
            secure: false,
            lastSeenAt: 1700000000000,
          },
        ],
      },
    });

    expect(RN.__mockNativeModule.startBridge).toHaveBeenCalledTimes(1);
    const callArgs = RN.__mockNativeModule.startBridge.mock.calls[0][0];
    expect(callArgs.offload).toEqual({
      enabled: true,
      discoverLAN: true,
      minLocalCapability: 12,
      rendezvousUrl: "wss://rendezvous.myapp.com",
      knownPeers: [
        expect.objectContaining({ deviceId: "peer-1", deviceName: "Studio Mac" }),
      ],
    });
  });
});

describe("DVAIBridge.start — license fields (v3.2.2)", () => {
  it("forwards licenseKeyPath through to the TurboModule untouched", async () => {
    RN.Platform.OS = "ios";
    RN.__mockNativeModule.startBridge.mockResolvedValueOnce({
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "llama",
      modelId: "Llama-3.2-1B-Instruct.Q4_K_M",
    });

    await DVAIBridge.start({
      backend: BackendKind.Llama,
      modelPath: "/tmp/model.gguf",
      licenseKeyPath: "/var/mobile/Containers/.../dvai-license.jwt",
    });

    expect(RN.__mockNativeModule.startBridge).toHaveBeenCalledTimes(1);
    const callArgs = RN.__mockNativeModule.startBridge.mock.calls[0][0];
    expect(callArgs.licenseKeyPath).toBe(
      "/var/mobile/Containers/.../dvai-license.jwt",
    );
  });

  it("forwards licenseToken through to the TurboModule untouched", async () => {
    RN.Platform.OS = "android";
    RN.__mockNativeModule.startBridge.mockResolvedValueOnce({
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "litert",
      modelId: "Gemma-2-2B-IT",
    });

    const fakeJwt =
      "eyJhbGciOiJFUzI1NiIsImtpZCI6InRlc3Qta2V5In0." +
      "eyJpc3MiOiJEVkFJLUJyaWRnZSJ9." +
      "sig";

    await DVAIBridge.start({
      backend: BackendKind.LiteRT,
      modelPath: "/data/data/com.example/files/model.litertlm",
      licenseToken: fakeJwt,
    });

    expect(RN.__mockNativeModule.startBridge).toHaveBeenCalledTimes(1);
    const callArgs = RN.__mockNativeModule.startBridge.mock.calls[0][0];
    expect(callArgs.licenseToken).toBe(fakeJwt);
  });

  it("forwards both license fields together — native picks the priority", async () => {
    RN.Platform.OS = "ios";
    RN.__mockNativeModule.startBridge.mockResolvedValueOnce({
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "llama",
      modelId: "m",
    });

    await DVAIBridge.start({
      backend: BackendKind.Llama,
      modelPath: "/tmp/m.gguf",
      licenseKeyPath: "/path/to/dvai-license.jwt",
      licenseToken: "eyJ.fake.jwt",
    });

    const callArgs = RN.__mockNativeModule.startBridge.mock.calls[0][0];
    expect(callArgs.licenseKeyPath).toBe("/path/to/dvai-license.jwt");
    expect(callArgs.licenseToken).toBe("eyJ.fake.jwt");
  });

  it("omitted license fields are not silently added by the JS facade", async () => {
    RN.Platform.OS = "ios";
    RN.__mockNativeModule.startBridge.mockResolvedValueOnce({
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "llama",
      modelId: "m",
    });

    await DVAIBridge.start({
      backend: BackendKind.Llama,
      modelPath: "/tmp/m.gguf",
    });

    const callArgs = RN.__mockNativeModule.startBridge.mock.calls[0][0];
    expect(callArgs.licenseKeyPath).toBeUndefined();
    expect(callArgs.licenseToken).toBeUndefined();
  });

  it("native license-validation errors surface as DVAIBridgeError", async () => {
    RN.Platform.OS = "ios";
    const nativeErr = Object.assign(
      new Error(
        "license token signature did not verify against kid \"prod-2026-01\"",
      ),
      { code: "configurationInvalid" },
    );
    RN.__mockNativeModule.startBridge.mockRejectedValueOnce(nativeErr);

    await expect(
      DVAIBridge.start({
        backend: BackendKind.Llama,
        modelPath: "/tmp/m.gguf",
        licenseToken: "tampered.jwt.token",
      }),
    ).rejects.toMatchObject({
      kind: "configurationInvalid",
    });
  });
});

describe("DVAIBridge.addListener('pairingRequest')", () => {
  it("registers a listener for inbound pairing requests and returns a removable subscription", () => {
    const requests: unknown[] = [];
    const sub = DVAIBridge.addListener("pairingRequest", (req) => {
      requests.push(req);
    });

    const samplePeer = {
      deviceId: "peer-2",
      deviceName: "Living Room iPad",
      dvaiVersion: "3.0.0",
      baseUrl: "http://192.168.1.43:38883/v1",
      loadedModels: [],
      capability: {},
      via: "mdns",
      secure: false,
      lastSeenAt: 1700000000000,
    };
    RN.__emit("DVAIBridgePairingRequest", {
      id: "req-abc",
      peer: samplePeer,
      peerDeviceName: samplePeer.deviceName,
      expiresAt: 1700000060000,
    });

    expect(requests).toHaveLength(1);
    expect(requests[0]).toMatchObject({
      id: "req-abc",
      peerDeviceName: "Living Room iPad",
    });

    sub.remove();
    RN.__emit("DVAIBridgePairingRequest", {
      id: "req-def",
      peer: samplePeer,
      peerDeviceName: samplePeer.deviceName,
      expiresAt: 1700000061000,
    });
    expect(requests).toHaveLength(1);
  });

  it("rejects an unknown event name eagerly with configurationInvalid", () => {
    expect(() =>
      // @ts-expect-error — runtime guard test; the type system already blocks this.
      DVAIBridge.addListener("not-a-real-event", () => undefined),
    ).toThrow(DVAIBridgeError);
  });
});

describe("DVAIBridge.respondToPairing", () => {
  it("forwards (requestId, approved) to the TurboModule", async () => {
    RN.__mockNativeModule.respondToPairing.mockResolvedValueOnce(undefined);
    await expect(
      DVAIBridge.respondToPairing("req-abc", true),
    ).resolves.toBeUndefined();
    expect(RN.__mockNativeModule.respondToPairing).toHaveBeenCalledWith(
      "req-abc",
      true,
    );
  });

  it("rewraps native errors as DVAIBridgeError with the kind preserved", async () => {
    const nativeErr = Object.assign(new Error("invalid pairing id"), {
      code: "configurationInvalid",
    });
    RN.__mockNativeModule.respondToPairing.mockRejectedValueOnce(nativeErr);

    await expect(
      DVAIBridge.respondToPairing("nope", false),
    ).rejects.toMatchObject({
      kind: "configurationInvalid",
      message: "invalid pairing id",
    });
  });
});
