/**
 * v3.2 — RN parallel to Android's CapabilityPrecheckTest.kt, iOS
 * CapabilityPrecheckTests.swift, .NET CapabilityPrecheckTests.cs, and
 * Flutter precheck_test.dart.
 *
 * The TS facade doesn't run the heuristic itself — `assessHardware()`
 * is a TurboModule call that delegates to the native iOS / Android
 * SDK and returns a `HardwareAssessment` object. These tests cover
 * the TS-side coercion contract:
 *
 *   - Valid native payloads round-trip into a HardwareAssessment.
 *   - Unknown mode strings throw `configurationInvalid`.
 *   - Missing optional fields fall back to documented safe defaults.
 *   - All three modes (`ok` / `offload-only` / `too-weak`) decode.
 */

jest.mock('react-native', () => {
  const listeners = new Map();
  const mockNativeModule = {
    startBridge: jest.fn(),
    stopBridge: jest.fn(),
    status: jest.fn(),
    downloadModel: jest.fn(),
    respondToPairing: jest.fn(),
    addListener: jest.fn(),
    removeListeners: jest.fn(),
    assessHardware: jest.fn(),
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
      getEnforcing: jest.fn(() => mockNativeModule),
      get: jest.fn(() => mockNativeModule),
    },
    __mockNativeModule: mockNativeModule,
    __emit: (eventName: string, payload: any) => {
      (listeners.get(eventName) ?? []).forEach((fn: any) => fn(payload));
    },
    __resetListeners: () => listeners.clear(),
  };
});

import * as RN from "react-native";
import { DVAIBridge } from "../DVAIBridge";
import { DVAIBridgeError } from "../errors";

// jest.setup.js doesn't pre-register `assessHardware` on the mock —
// add it lazily so we can override per test.
beforeAll(() => {
  RN.__mockNativeModule.assessHardware = jest.fn();
});

beforeEach(() => {
  RN.__mockNativeModule.assessHardware.mockReset();
  RN.Platform.OS = "ios";
});

describe("DVAIBridge.assessHardware — coercion contract", () => {
  it("decodes a high-end ok assessment", async () => {
    RN.__mockNativeModule.assessHardware.mockResolvedValueOnce({
      mode: "ok",
      tokPerSec: 42.5,
      reason: "42.5 tok/s — ok.",
      hints: {
        hasNpu: false,
        ramGb: 32,
        gpuClass: "discrete",
        cpuClass: "high",
      },
    });
    const a = await DVAIBridge.assessHardware();
    expect(a.mode).toBe("ok");
    expect(a.tokPerSec).toBe(42.5);
    expect(a.reason).toContain("ok");
    expect(a.hints.hasNpu).toBe(false);
    expect(a.hints.ramGb).toBe(32);
    expect(a.hints.gpuClass).toBe("discrete");
    expect(a.hints.cpuClass).toBe("high");
  });

  it("decodes an offload-only mid-range assessment", async () => {
    RN.__mockNativeModule.assessHardware.mockResolvedValueOnce({
      mode: "offload-only",
      tokPerSec: 8.0,
      reason: "8.0 tok/s — below comfort, offload only.",
      hints: {
        hasNpu: false,
        ramGb: 8,
        gpuClass: "integrated",
        cpuClass: "mid",
      },
    });
    const a = await DVAIBridge.assessHardware();
    expect(a.mode).toBe("offload-only");
    expect(a.tokPerSec).toBe(8.0);
    expect(a.hints.gpuClass).toBe("integrated");
    expect(a.hints.cpuClass).toBe("mid");
  });

  it("decodes a too-weak low-end assessment", async () => {
    RN.__mockNativeModule.assessHardware.mockResolvedValueOnce({
      mode: "too-weak",
      tokPerSec: 0.5,
      reason: "0.5 tok/s — too weak.",
      hints: {
        hasNpu: false,
        ramGb: 2,
        gpuClass: "none",
        cpuClass: "low",
      },
    });
    const a = await DVAIBridge.assessHardware();
    expect(a.mode).toBe("too-weak");
    expect(a.tokPerSec).toBeLessThan(3.0);
    expect(a.hints.gpuClass).toBe("none");
    expect(a.hints.cpuClass).toBe("low");
  });

  it("decodes an apple-silicon assessment", async () => {
    RN.__mockNativeModule.assessHardware.mockResolvedValueOnce({
      mode: "ok",
      tokPerSec: 50.0,
      reason: "apple silicon",
      hints: {
        hasNpu: true,
        ramGb: 16,
        gpuClass: "apple-silicon",
        cpuClass: "high",
      },
    });
    const a = await DVAIBridge.assessHardware();
    expect(a.hints.gpuClass).toBe("apple-silicon");
    expect(a.hints.hasNpu).toBe(true);
  });

  it("forwards explicit hardwareMinimum + minLocalCapability to native", async () => {
    RN.__mockNativeModule.assessHardware.mockResolvedValueOnce({
      mode: "ok",
      tokPerSec: 30,
      reason: "r",
      hints: { hasNpu: false, ramGb: 16, gpuClass: "discrete", cpuClass: "high" },
    });
    await DVAIBridge.assessHardware(5.0, 12.0);
    expect(RN.__mockNativeModule.assessHardware).toHaveBeenCalledWith(5.0, 12.0);
  });

  it("uses the canonical defaults (3.0 / 10.0) when called without args", async () => {
    RN.__mockNativeModule.assessHardware.mockResolvedValueOnce({
      mode: "ok",
      tokPerSec: 30,
      reason: "r",
      hints: { hasNpu: false, ramGb: 16, gpuClass: "discrete", cpuClass: "high" },
    });
    await DVAIBridge.assessHardware();
    expect(RN.__mockNativeModule.assessHardware).toHaveBeenCalledWith(3.0, 10.0);
  });
});

describe("DVAIBridge.assessHardware — error paths", () => {
  it("throws configurationInvalid when native returns a non-object", async () => {
    RN.__mockNativeModule.assessHardware.mockResolvedValueOnce(null);
    await expect(DVAIBridge.assessHardware()).rejects.toBeInstanceOf(DVAIBridgeError);
    await expect(DVAIBridge.assessHardware()).rejects.toMatchObject({
      kind: "configurationInvalid",
    });
  });

  it("throws configurationInvalid for unknown mode strings", async () => {
    RN.__mockNativeModule.assessHardware.mockResolvedValue({
      mode: "rocket-fuel",
      tokPerSec: 100,
      reason: "r",
      hints: { hasNpu: false, ramGb: 32, gpuClass: "discrete", cpuClass: "high" },
    });
    // Don't silently fall back — better to surface the malformed native
    // response so consumers can investigate. (Different policy from the
    // wire-decoder defaults on iOS / Android / Flutter; on RN we throw.)
    await expect(DVAIBridge.assessHardware()).rejects.toMatchObject({
      kind: "configurationInvalid",
    });
  });

  it("falls back to safe defaults for missing hint subfields", async () => {
    // Mode is valid; native forgot to populate `hints.gpuClass` /
    // `cpuClass`. Coercer fills the safe defaults documented in
    // DeviceCapabilityHints.
    RN.__mockNativeModule.assessHardware.mockResolvedValueOnce({
      mode: "offload-only",
      tokPerSec: 5.0,
      reason: "r",
      hints: {
        hasNpu: true,
        ramGb: 4,
        // gpuClass + cpuClass missing
      },
    });
    const a = await DVAIBridge.assessHardware();
    expect(a.hints.gpuClass).toBe("integrated");
    expect(a.hints.cpuClass).toBe("mid");
    expect(a.hints.hasNpu).toBe(true);
    expect(a.hints.ramGb).toBe(4);
  });

  it("propagates native rejections as DVAIBridgeError", async () => {
    RN.__mockNativeModule.assessHardware.mockRejectedValueOnce({
      code: "NATIVE_FAILURE",
      message: "something exploded in the SDK",
    });
    await expect(DVAIBridge.assessHardware()).rejects.toBeInstanceOf(DVAIBridgeError);
  });
});

describe("PrecheckMode wire-format strings", () => {
  it("uses kebab-case across all three modes", () => {
    // Type-level assertion: TS compile would already fail if these
    // strings drifted, but lock them in a runtime test too so the
    // contract stays visible alongside Flutter / iOS / Android / .NET.
    const ok: import("../types").PrecheckMode = "ok";
    const off: import("../types").PrecheckMode = "offload-only";
    const tw: import("../types").PrecheckMode = "too-weak";
    expect(ok).toBe("ok");
    expect(off).toBe("offload-only");
    expect(tw).toBe("too-weak");
  });

  it("GpuClass includes apple-silicon kebab-case", () => {
    const g: import("../types").GpuClass = "apple-silicon";
    expect(g).toBe("apple-silicon");
  });
});
