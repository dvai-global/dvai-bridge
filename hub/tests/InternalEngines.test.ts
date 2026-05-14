/**
 * Tests for the v3.2.x multi-internal-engine surface.
 *
 * Verifies:
 *   - Multiple internal engines surface as separate EngineSummary entries
 *   - setEngineEnabled rebuilds the DVAI server with the new backend on swap
 *   - localBackends reflect the active engine's modelId
 *   - Mutual exclusivity holds across the internal/external boundary
 *   - Disabling the active internal engine tears down the DVAI server
 *   - The list-order is preserved (declaration order is UI render order)
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { PeerMode } from "../peer-mode/PeerMode.js";
import type { EngineAdapter, ChatRequest, ChatResponse } from "../peer-mode/EngineBridge.js";

let tmpDir: string;

beforeEach(async () => {
  tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "dvai-hub-internal-engines-"));
});

afterEach(async () => {
  await fs.rm(tmpDir, { recursive: true, force: true });
});

function fakeAdapter(name: string): EngineAdapter {
  return {
    name,
    detect: async () => true,
    enumerateCachedModels: async () => [],
    serveRequest: async (): Promise<ChatResponse> => ({ status: 200, headers: {}, body: {} }),
    close: async () => undefined,
  };
}

describe("InternalEngines — listing", () => {
  it("returns one EngineSummary per InternalEngineConfig, in declaration order", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      internalEngines: [
        { name: "Transformers.js (Internal)", backend: "transformers", modelId: "tf-model", detected: true },
        { name: "node-llama-cpp (Internal)", backend: "native", modelId: "/path/to/gguf", detected: true },
      ],
      onPairingRequest: async () => true,
    });
    await peer.start();
    const summary = peer.getDetectedEngines();
    expect(summary.length).toBe(2);
    expect(summary[0]?.name).toBe("Transformers.js (Internal)");
    expect(summary[1]?.name).toBe("node-llama-cpp (Internal)");
    expect(summary[0]?.detected).toBe(true);
    expect(summary[1]?.detected).toBe(true);
    // Neither enabled at first start (host's auto-enable lives in server.ts, not PeerMode).
    expect(summary[0]?.enabled).toBe(false);
    expect(summary[1]?.enabled).toBe(false);
  });

  it("internal engines come before external engines in the array", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: true,
      engineAdapters: [fakeAdapter("ollama"), fakeAdapter("lmstudio")],
      internalEngines: [
        { name: "Transformers.js (Internal)", backend: "transformers", modelId: "m", detected: true },
      ],
      onPairingRequest: async () => true,
    });
    await peer.start();
    const summary = peer.getDetectedEngines();
    expect(summary.map(e => e.name)).toEqual([
      "Transformers.js (Internal)",
      "ollama",
      "lmstudio",
    ]);
  });

  it("respects detected:false (still listed but reported as unavailable)", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      internalEngines: [
        // Simulates node-llama-cpp without a configured model path
        { name: "node-llama-cpp (Internal)", backend: "native", modelId: "placeholder", detected: false },
      ],
      onPairingRequest: async () => true,
    });
    await peer.start();
    const summary = peer.getDetectedEngines();
    expect(summary[0]?.name).toBe("node-llama-cpp (Internal)");
    expect(summary[0]?.detected).toBe(false);
  });
});

describe("InternalEngines — backend swap", () => {
  it("setEngineEnabled constructs DVAI with the right backend identifier", async () => {
    const constructedBackends: string[] = [];
    const fakeDvai = {
      baseUrl: "http://x",
      port: 1234,
      initialize: vi.fn(async () => undefined),
      unload: vi.fn(async () => undefined),
    };
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      internalEngines: [
        { name: "TF", backend: "transformers", modelId: "tf-m", detected: true },
        { name: "Llama", backend: "native", modelId: "/p/gguf", detected: true },
      ],
      onPairingRequest: async () => true,
      dvaiFactory: (backend, _cb) => {
        constructedBackends.push(backend);
        return fakeDvai;
      },
    });
    await peer.start();
    await peer.setEngineEnabled("TF", true);
    expect(constructedBackends).toEqual(["transformers"]);
    expect(fakeDvai.initialize).toHaveBeenCalledTimes(1);

    // Swap to the other internal engine — should unload the old one,
    // construct a new one with the new backend identifier.
    await peer.setEngineEnabled("Llama", true);
    expect(constructedBackends).toEqual(["transformers", "native"]);
    expect(fakeDvai.unload).toHaveBeenCalledTimes(1);
    expect(fakeDvai.initialize).toHaveBeenCalledTimes(2);
  });

  it("registers the active engine's modelId in localBackends", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      internalEngines: [
        { name: "TF", backend: "transformers", modelId: "onnx-community/Llama-3.2-1B", detected: true },
      ],
      onPairingRequest: async () => true,
      dvaiFactory: (_backend, _cb) => ({
        baseUrl: "http://x", port: 1, initialize: async () => undefined, unload: async () => undefined,
      }),
    });
    await peer.start();
    await peer.setEngineEnabled("TF", true);
    expect(peer.getCachedModels().length).toBe(1);
    expect(peer.getCachedModels()[0]?.engineModelId).toBe("onnx-community/Llama-3.2-1B");
  });

  it("disabling the active internal engine clears localBackends and unloads DVAI", async () => {
    const fakeDvai = {
      baseUrl: "http://x", port: 1, initialize: vi.fn(async () => undefined), unload: vi.fn(async () => undefined),
    };
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      internalEngines: [
        { name: "TF", backend: "transformers", modelId: "m", detected: true },
      ],
      onPairingRequest: async () => true,
      dvaiFactory: () => fakeDvai,
    });
    await peer.start();
    await peer.setEngineEnabled("TF", true);
    expect(peer.getCachedModels().length).toBe(1);

    await peer.setEngineEnabled("TF", false);
    expect(peer.getCachedModels().length).toBe(0);
    expect(peer.getDetectedEngines()[0]?.enabled).toBe(false);
    expect(fakeDvai.unload).toHaveBeenCalledTimes(1);
  });

  it("enabling an external engine tears down the active internal DVAI", async () => {
    const fakeDvai = {
      baseUrl: "http://x", port: 1, initialize: vi.fn(async () => undefined), unload: vi.fn(async () => undefined),
    };
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: true,
      engineAdapters: [fakeAdapter("ollama")],
      internalEngines: [
        { name: "TF", backend: "transformers", modelId: "m", detected: true },
      ],
      onPairingRequest: async () => true,
      dvaiFactory: () => fakeDvai,
    });
    await peer.start();
    await peer.setEngineEnabled("TF", true);
    expect(fakeDvai.initialize).toHaveBeenCalledTimes(1);

    await peer.setEngineEnabled("ollama", true);
    expect(fakeDvai.unload).toHaveBeenCalledTimes(1);
    expect(peer.getDetectedEngines().find(e => e.name === "TF")?.enabled).toBe(false);
    expect(peer.getDetectedEngines().find(e => e.name === "ollama")?.enabled).toBe(true);
  });

  it("enabling the same active engine again is a no-op (no double-construct)", async () => {
    let initCount = 0;
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      internalEngines: [
        { name: "TF", backend: "transformers", modelId: "m", detected: true },
      ],
      onPairingRequest: async () => true,
      dvaiFactory: () => ({
        baseUrl: "http://x", port: 1,
        initialize: async () => { initCount++; },
        unload: async () => undefined,
      }),
    });
    await peer.start();
    await peer.setEngineEnabled("TF", true);
    await peer.setEngineEnabled("TF", true);
    await peer.setEngineEnabled("TF", true);
    expect(initCount).toBe(1);
  });
});
