/**
 * Unit test for the `useDVAIBridgeState` React hook.
 *
 * Renders a tiny consumer component via React's test renderer (the
 * standalone `react-test-renderer` package is enough — we don't need
 * @testing-library/react-native because we're not asserting on RN-native
 * widget output, only on the hook's returned state object).
 *
 * The hook subscribes to `DVAIBridge.addProgressListener` and refetches
 * `status()` on `completed phase=start`. We dispatch fake events via
 * `RN.__emit("DVAIBridgeProgress", …)` and assert the captured state.
 */

import { act } from "react";
import * as React from "react";
import * as TestRenderer from "react-test-renderer";

import { useDVAIBridgeState } from "../hooks/useDVAIBridgeState";

const RN = require("react-native");

// A tiny consumer component that captures the hook's state into a ref so
// tests can assert it after each act() boundary.
function StateCapture(props: { onState: (s: unknown) => void }) {
  const state = useDVAIBridgeState();
  React.useEffect(() => {
    props.onState(state);
  });
  return null;
}

beforeEach(() => {
  RN.__resetListeners();
  RN.__mockNativeModule.startBridge.mockReset();
  RN.__mockNativeModule.stopBridge.mockReset();
  RN.__mockNativeModule.status.mockReset();
  RN.__mockNativeModule.addListener.mockReset();
  RN.__mockNativeModule.removeListeners.mockReset();
  RN.Platform.OS = "ios";
});

describe("useDVAIBridgeState", () => {
  it("starts with isReady=false and updates on `completed phase=start`", async () => {
    // Initial status: not running.
    RN.__mockNativeModule.status.mockResolvedValueOnce({ running: false });

    const captured: unknown[] = [];
    let renderer!: TestRenderer.ReactTestRenderer;
    await act(async () => {
      renderer = TestRenderer.create(
        <StateCapture onState={(s) => captured.push(s)} />,
      );
    });

    // After mount + initial status fetch, isReady is false.
    const last = captured[captured.length - 1] as { isReady: boolean };
    expect(last.isReady).toBe(false);

    // Now: simulate the bridge completing a start. The hook's listener
    // should re-fetch status, which we mock to return the running state.
    RN.__mockNativeModule.status.mockResolvedValueOnce({
      running: true,
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "llama",
      modelId: "Llama-3.2-1B-Instruct.Q4_K_M",
    });

    await act(async () => {
      RN.__emit("DVAIBridgeProgress", {
        kind: "completed",
        phase: "start",
      });
      // Yield once so the chained status() promise resolves before assertions.
      await Promise.resolve();
      await Promise.resolve();
    });

    const after = captured[captured.length - 1] as {
      isReady: boolean;
      baseUrl?: string;
      backend?: string;
    };
    expect(after.isReady).toBe(true);
    expect(after.baseUrl).toBe("http://127.0.0.1:38883/v1");
    expect(after.backend).toBe("llama");

    await act(async () => {
      renderer.unmount();
    });
  });

  it("stashes the most recent progress event under `lastProgress`", async () => {
    RN.__mockNativeModule.status.mockResolvedValueOnce({ running: false });

    const captured: unknown[] = [];
    let renderer!: TestRenderer.ReactTestRenderer;
    await act(async () => {
      renderer = TestRenderer.create(
        <StateCapture onState={(s) => captured.push(s)} />,
      );
    });

    await act(async () => {
      RN.__emit("DVAIBridgeProgress", {
        kind: "progress",
        phase: "download",
        percent: 42,
      });
      await Promise.resolve();
    });

    const last = captured[captured.length - 1] as {
      lastProgress?: { kind: string; phase: string; percent?: number };
    };
    expect(last.lastProgress).toMatchObject({
      kind: "progress",
      phase: "download",
      percent: 42,
    });

    await act(async () => {
      renderer.unmount();
    });
  });

  it("clears running state on `completed phase=stop`", async () => {
    // Bridge starts already running.
    RN.__mockNativeModule.status.mockResolvedValueOnce({
      running: true,
      baseUrl: "http://127.0.0.1:38883/v1",
      port: 38883,
      backend: "llama",
      modelId: "test",
    });

    const captured: unknown[] = [];
    let renderer!: TestRenderer.ReactTestRenderer;
    await act(async () => {
      renderer = TestRenderer.create(
        <StateCapture onState={(s) => captured.push(s)} />,
      );
      await Promise.resolve();
    });

    expect((captured[captured.length - 1] as { isReady: boolean }).isReady).toBe(true);

    await act(async () => {
      RN.__emit("DVAIBridgeProgress", { kind: "completed", phase: "stop" });
      await Promise.resolve();
    });

    expect((captured[captured.length - 1] as { isReady: boolean }).isReady).toBe(false);

    await act(async () => {
      renderer.unmount();
    });
  });

  it("forces isReady=false on `failed phase=start`", async () => {
    RN.__mockNativeModule.status.mockResolvedValueOnce({ running: false });

    const captured: unknown[] = [];
    let renderer!: TestRenderer.ReactTestRenderer;
    await act(async () => {
      renderer = TestRenderer.create(
        <StateCapture onState={(s) => captured.push(s)} />,
      );
    });

    await act(async () => {
      RN.__emit("DVAIBridgeProgress", {
        kind: "failed",
        phase: "start",
        error: { kind: "modelLoadFailed", message: "bad model" },
      });
      await Promise.resolve();
    });

    const last = captured[captured.length - 1] as {
      isReady: boolean;
      lastProgress?: { kind: string };
    };
    expect(last.isReady).toBe(false);
    expect(last.lastProgress?.kind).toBe("failed");

    await act(async () => {
      renderer.unmount();
    });
  });
});
