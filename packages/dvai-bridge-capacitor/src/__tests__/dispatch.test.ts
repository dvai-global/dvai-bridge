import { describe, it, expect, vi, beforeEach } from "vitest";

const mockNativePlugin = {
  start: vi.fn(async () => ({ baseUrl: "http://127.0.0.1:38883/v1", port: 38883, backend: "llama", modelId: "test" })),
  stop: vi.fn(async () => undefined),
  status: vi.fn(async () => ({ running: true })),
};

vi.mock("@capacitor/core", () => ({
  registerPlugin: vi.fn((_name: string) => mockNativePlugin),
  Capacitor: { getPlatform: () => "ios" },
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

describe("plugin-not-installed errors", () => {
  it("wraps Capacitor's UNIMPLEMENTED error with actionable message", async () => {
    vi.resetModules();
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: vi.fn(() => ({
        start: async () => {
          throw new Error("DVAIBridgeLlama not implemented on android");
        },
      })),
      Capacitor: { getPlatform: () => "android" },
    }));
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();

    await expect(
      dispatch.start({ backend: "llama", modelPath: "/m.gguf" }),
    ).rejects.toThrow(/npm install @dvai-bridge\/capacitor-llama && npx cap sync/);
  });
});

describe("DVAIBridge offload + pairing surface (v3.0)", () => {
  beforeEach(async () => {
    vi.resetModules();
    vi.clearAllMocks();
  });

  it("forwards opts.offload through to the native plugin's start()", async () => {
    const startSpy = vi.fn(async () => ({
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "llama" as const,
      modelId: "test",
    }));
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: vi.fn(() => ({
        start: startSpy,
        stop: vi.fn(async () => undefined),
        status: vi.fn(async () => ({ running: true })),
        addListener: vi.fn(async () => ({ remove: async () => undefined })),
        respondToPairing: vi.fn(async () => undefined),
      })),
      Capacitor: { getPlatform: () => "ios" },
    }));
    const { DVAIBridge } = await import("../index");
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();

    await DVAIBridge.start({
      backend: "llama",
      modelPath: "/m.gguf",
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

    expect(startSpy).toHaveBeenCalledTimes(1);
    const callArgs = startSpy.mock.calls[0][0] as Record<string, unknown>;
    expect(callArgs.offload).toMatchObject({
      enabled: true,
      discoverLAN: true,
      minLocalCapability: 12,
      rendezvousUrl: "wss://rendezvous.myapp.com",
    });
  });

  it("addListener('pairingRequest') routes through to the active plugin", async () => {
    const addListenerSpy = vi.fn(async () => ({
      remove: async () => undefined,
    }));
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: vi.fn(() => ({
        start: vi.fn(async () => ({
          baseUrl: "http://127.0.0.1:38883/v1",
          port: 38883,
          backend: "llama",
          modelId: "test",
        })),
        stop: vi.fn(async () => undefined),
        status: vi.fn(async () => ({ running: true })),
        addListener: addListenerSpy,
        respondToPairing: vi.fn(async () => undefined),
      })),
      Capacitor: { getPlatform: () => "ios" },
    }));
    const { DVAIBridge } = await import("../index");
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();

    await DVAIBridge.start({ backend: "llama", modelPath: "/m.gguf" });
    const cb = vi.fn();
    await DVAIBridge.addListener("pairingRequest", cb);

    expect(addListenerSpy).toHaveBeenCalledWith("pairingRequest", cb);
  });

  it("addListener throws if called before start()", async () => {
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: vi.fn(() => ({})),
      Capacitor: { getPlatform: () => "ios" },
    }));
    const { DVAIBridge } = await import("../index");
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();

    await expect(
      DVAIBridge.addListener("pairingRequest", () => undefined),
    ).rejects.toThrow(/before start/);
  });

  it("addListener rejects unknown event names", async () => {
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: vi.fn(() => ({
        start: vi.fn(async () => ({
          baseUrl: "x",
          port: 1,
          backend: "llama",
          modelId: "x",
        })),
        addListener: vi.fn(),
      })),
      Capacitor: { getPlatform: () => "ios" },
    }));
    const { DVAIBridge } = await import("../index");
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();
    await DVAIBridge.start({ backend: "llama", modelPath: "/m.gguf" });
    await expect(
      // @ts-expect-error — runtime guard test; the type system already blocks this.
      DVAIBridge.addListener("not-a-real-event", () => undefined),
    ).rejects.toThrow(/unknown event name/);
  });

  it("respondToPairing forwards (requestId, approved) to the native plugin", async () => {
    const respondSpy = vi.fn(async () => undefined);
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: vi.fn(() => ({
        start: vi.fn(async () => ({
          baseUrl: "http://127.0.0.1:38883/v1",
          port: 38883,
          backend: "llama",
          modelId: "test",
        })),
        stop: vi.fn(async () => undefined),
        status: vi.fn(async () => ({ running: true })),
        addListener: vi.fn(async () => ({ remove: async () => undefined })),
        respondToPairing: respondSpy,
      })),
      Capacitor: { getPlatform: () => "ios" },
    }));
    const { DVAIBridge } = await import("../index");
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();

    await DVAIBridge.start({ backend: "llama", modelPath: "/m.gguf" });
    await DVAIBridge.respondToPairing("req-abc", true);

    expect(respondSpy).toHaveBeenCalledWith({
      requestId: "req-abc",
      approved: true,
    });
  });

  it("respondToPairing throws if called before start()", async () => {
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: vi.fn(() => ({})),
      Capacitor: { getPlatform: () => "ios" },
    }));
    const { DVAIBridge } = await import("../index");
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();

    await expect(
      DVAIBridge.respondToPairing("req-abc", true),
    ).rejects.toThrow(/before start/);
  });
});

describe("DVAIBridge license fields (v3.2.2)", () => {
  beforeEach(async () => {
    vi.resetModules();
    vi.clearAllMocks();
  });

  it("forwards opts.licenseKeyPath through to the native plugin's start()", async () => {
    const startSpy = vi.fn(async () => ({
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "llama" as const,
      modelId: "test",
    }));
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: vi.fn(() => ({
        start: startSpy,
        stop: vi.fn(async () => undefined),
        status: vi.fn(async () => ({ running: true })),
      })),
      Capacitor: { getPlatform: () => "ios" },
    }));
    const { DVAIBridge } = await import("../index");
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();

    await DVAIBridge.start({
      backend: "llama",
      modelPath: "/m.gguf",
      licenseKeyPath: "/var/mobile/Containers/.../dvai-license.jwt",
    });

    expect(startSpy).toHaveBeenCalledTimes(1);
    const callArgs = ((startSpy.mock.calls as unknown[][])[0]?.[0] ?? {}) as Record<string, unknown>;
    expect(callArgs.licenseKeyPath).toBe(
      "/var/mobile/Containers/.../dvai-license.jwt",
    );
  });

  it("forwards opts.licenseToken through to the native plugin's start()", async () => {
    const startSpy = vi.fn(async () => ({
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "llama" as const,
      modelId: "test",
    }));
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: vi.fn(() => ({
        start: startSpy,
        stop: vi.fn(async () => undefined),
        status: vi.fn(async () => ({ running: true })),
      })),
      Capacitor: { getPlatform: () => "ios" },
    }));
    const { DVAIBridge } = await import("../index");
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();

    const fakeJwt =
      "eyJhbGciOiJFUzI1NiIsImtpZCI6InRlc3Qta2V5In0." +
      "eyJpc3MiOiJEVkFJLUJyaWRnZSJ9." +
      "sig";

    await DVAIBridge.start({
      backend: "llama",
      modelPath: "/m.gguf",
      licenseToken: fakeJwt,
    });

    expect(startSpy).toHaveBeenCalledTimes(1);
    const callArgs = ((startSpy.mock.calls as unknown[][])[0]?.[0] ?? {}) as Record<string, unknown>;
    expect(callArgs.licenseToken).toBe(fakeJwt);
  });

  it("forwards both license fields together — native picks the priority", async () => {
    const startSpy = vi.fn(async () => ({
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "llama" as const,
      modelId: "test",
    }));
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: vi.fn(() => ({
        start: startSpy,
        stop: vi.fn(async () => undefined),
        status: vi.fn(async () => ({ running: true })),
      })),
      Capacitor: { getPlatform: () => "ios" },
    }));
    const { DVAIBridge } = await import("../index");
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();

    await DVAIBridge.start({
      backend: "llama",
      modelPath: "/m.gguf",
      licenseKeyPath: "/path/to/dvai-license.jwt",
      licenseToken: "eyJ.fake.jwt",
    });

    const callArgs = ((startSpy.mock.calls as unknown[][])[0]?.[0] ?? {}) as Record<string, unknown>;
    expect(callArgs.licenseKeyPath).toBe("/path/to/dvai-license.jwt");
    expect(callArgs.licenseToken).toBe("eyJ.fake.jwt");
  });

  it("does not require license fields — start() works without them", async () => {
    const startSpy = vi.fn(async () => ({
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "llama" as const,
      modelId: "test",
    }));
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: vi.fn(() => ({
        start: startSpy,
        stop: vi.fn(async () => undefined),
        status: vi.fn(async () => ({ running: true })),
      })),
      Capacitor: { getPlatform: () => "ios" },
    }));
    const { DVAIBridge } = await import("../index");
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();

    await DVAIBridge.start({ backend: "llama", modelPath: "/m.gguf" });

    const callArgs = ((startSpy.mock.calls as unknown[][])[0]?.[0] ?? {}) as Record<string, unknown>;
    expect(callArgs.licenseKeyPath).toBeUndefined();
    expect(callArgs.licenseToken).toBeUndefined();
  });
});

describe("Android + foundation backend", () => {
  it("rejects with a clear iOS-only message before touching the native plugin", async () => {
    vi.resetModules();
    const registerPluginSpy = vi.fn(() => mockNativePlugin);
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: registerPluginSpy,
      Capacitor: { getPlatform: () => "android" },
    }));
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();

    await expect(dispatch.start({ backend: "foundation" })).rejects.toThrow(
      /Apple Foundation Models is iOS-only/,
    );
    // The dispatcher must short-circuit before registerPlugin is even called.
    expect(registerPluginSpy).not.toHaveBeenCalled();
  });

  it("allows backend:'foundation' on iOS platform", async () => {
    vi.resetModules();
    vi.doMock("@capacitor/core", () => ({
      registerPlugin: vi.fn(() => mockNativePlugin),
      Capacitor: { getPlatform: () => "ios" },
    }));
    const { dispatch } = await import("../dispatch");
    dispatch.__reset();

    await expect(
      dispatch.start({ backend: "foundation" }),
    ).resolves.toMatchObject({ backend: "llama" });
    // (Mock returns "llama" as the canned backend; the test exercises the
    // platform gate, not the result content.)
  });
});
