import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { PeerMode } from "../peer-mode/PeerMode.js";
import type { EngineAdapter, ChatRequest, ChatResponse } from "../peer-mode/EngineBridge.js";

let tmpDir: string;

beforeEach(async () => {
  tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "dvai-hub-exclusivity-"));
});

afterEach(async () => {
  await fs.rm(tmpDir, { recursive: true, force: true });
});

function fakeAdapter(name: string): EngineAdapter {
  return {
    name,
    detect: async () => true,
    enumerateCachedModels: async () => [],
    serveRequest: async () => ({} as any),
    close: async () => undefined,
  };
}

describe("Engine Exclusivity & Rescan", () => {
  it("enabling an external engine disables the internal one and other external ones (case-insensitive)", async () => {
    const ollama = fakeAdapter("ollama");
    const lmstudio = fakeAdapter("lmstudio");
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: true,
      engineAdapters: [ollama, lmstudio],
      // Multi-engine API: declare the internal engine in the catalog
      // (replaces the old setInternalEngineName setter). Test mode runs
      // without a dvaiFactory so DVAI construction is a no-op — we're
      // exercising the exclusivity state machine, not the HTTP plane.
      internalEngines: [
        {
          name: "Transformers.js (Internal)",
          backend: "transformers",
          modelId: "test-model",
          detected: true,
        },
      ],
      onPairingRequest: async () => true,
    });

    await peer.start();

    // Initial state: everything disabled by default
    let engines = peer.getDetectedEngines();
    expect(engines.find(e => e.name.includes("Internal"))?.enabled).toBe(false);
    expect(engines.find(e => e.name === "ollama")?.enabled).toBe(false);

    // 1. Enable internal
    await peer.setEngineEnabled("Transformers.js (Internal)", true);
    engines = peer.getDetectedEngines();
    expect(engines.find(e => e.name.includes("Internal"))?.enabled).toBe(true);
    expect(engines.find(e => e.name === "ollama")?.enabled).toBe(false);

    // 2. Enable external (Ollama) with different casing
    await peer.setEngineEnabled("OLLAMA", true);
    engines = peer.getDetectedEngines();
    expect(engines.find(e => e.name.includes("Internal"))?.enabled).toBe(false);
    expect(engines.find(e => e.name === "ollama")?.enabled).toBe(true);
    expect(engines.find(e => e.name === "lmstudio")?.enabled).toBe(false);

    // 3. Enable another external (LMStudio)
    await peer.setEngineEnabled("lmstudio", true);
    engines = peer.getDetectedEngines();
    expect(engines.find(e => e.name === "ollama")?.enabled).toBe(false);
    expect(engines.find(e => e.name === "lmstudio")?.enabled).toBe(true);

    // 4. Disable LMStudio
    await peer.setEngineEnabled("lmstudio", false);
    engines = peer.getDetectedEngines();
    expect(engines.find(e => e.name === "lmstudio")?.enabled).toBe(false);
  });

  it("rescan preserves the enabled state of an engine", async () => {
    const ollama = fakeAdapter("ollama");
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: true,
      engineAdapters: [ollama],
      onPairingRequest: async () => true,
    });
    await peer.start();

    // Enable it
    await peer.setEngineEnabled("ollama", true);
    expect(peer.getDetectedEngines().find(e => e.name === "ollama")?.enabled).toBe(true);

    // Rescan
    await peer.invalidateEngineCache("ollama");

    // Should still be enabled
    const engines = peer.getDetectedEngines();
    const summary = engines.find(e => e.name === "ollama");
    expect(summary?.enabled).toBe(true);
    expect(summary?.detected).toBe(true);
  });

  it("rescan handles internal engine name without crashing", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      // Internal engine declared via the catalog; passing its display
      // name to invalidateEngineCache should be a benign no-op (internal
      // engines aren't backed by an adapter so there's nothing to probe).
      internalEngines: [
        {
          name: "Internal Runtime",
          backend: "transformers",
          modelId: "test-model",
          detected: true,
        },
      ],
      onPairingRequest: async () => true,
    });
    await peer.start();

    // Should not throw
    await peer.invalidateEngineCache("Internal Runtime");
  });
});
