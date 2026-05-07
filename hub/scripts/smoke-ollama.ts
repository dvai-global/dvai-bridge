/**
 * Phase 4 smoke test — OllamaAdapter against a real `localhost:11434`.
 *
 * Run after `pnpm build:peer-mode`:
 *   node dist/scripts/smoke-ollama.js
 *
 * Optional env:
 *   OLLAMA_BASE_URL     override base URL (default http://127.0.0.1:11434)
 *   OLLAMA_USE_SUBPROCESS=1   use `ollama ls` instead of /api/tags
 *
 * Verifies:
 *   1. detect() returns true.
 *   2. enumerateCachedModels() returns at least one row.
 *   3. Each row's parsed descriptor is printed for visual inspection.
 */

import { OllamaAdapter } from "../peer-mode/adapters/OllamaAdapter.js";

async function main(): Promise<void> {
  const baseUrl = process.env.OLLAMA_BASE_URL;
  const useSubprocess = process.env.OLLAMA_USE_SUBPROCESS === "1";
  const adapter = new OllamaAdapter({
    ...(baseUrl !== undefined ? { baseUrl } : {}),
    useSubprocessEnumeration: useSubprocess,
  });

  console.log("→ Ollama adapter smoke test");
  console.log(`  baseUrl: ${baseUrl ?? "http://127.0.0.1:11434"}`);
  console.log(`  enumeration path: ${useSubprocess ? "ollama ls (subprocess)" : "/api/tags (HTTP)"}`);
  console.log("");

  const detected = await adapter.detect();
  console.log(`detect(): ${detected ? "✅ true" : "❌ false"}`);
  if (!detected) {
    console.log("");
    console.log("Ollama is not reachable. Start it (`ollama serve` or the");
    console.log("Ollama desktop app) and re-run.");
    process.exit(1);
  }

  const models = await adapter.enumerateCachedModels();
  console.log(`enumerateCachedModels(): ${models.length} row(s)`);
  console.log("");

  if (models.length === 0) {
    console.log("Ollama is reachable but has no cached models. Try:");
    console.log("  ollama pull llama3.2:1b");
    console.log("…and re-run.");
    process.exit(0);
  }

  // Pretty table.
  const widths = { id: 0, family: 0, version: 0, size: 0, quant: 0, type: 0 };
  for (const m of models) {
    const d = m.descriptor;
    widths.id = Math.max(widths.id, m.engineModelId.length);
    widths.family = Math.max(widths.family, d.family.length);
    widths.version = Math.max(widths.version, (d.version ?? "—").length);
    widths.size = Math.max(widths.size, d.size.length);
    widths.quant = Math.max(widths.quant, (d.quant ?? "—").length);
    widths.type = Math.max(widths.type, d.type.length);
  }
  const pad = (s: string, w: number) => s.padEnd(w);
  console.log(
    `  ${pad("model id", widths.id)}  ${pad("family", widths.family)}  ${pad(
      "version",
      widths.version,
    )}  ${pad("size", widths.size)}  ${pad("quant", widths.quant)}  ${pad("type", widths.type)}`,
  );
  console.log(
    `  ${"-".repeat(widths.id)}  ${"-".repeat(widths.family)}  ${"-".repeat(
      widths.version,
    )}  ${"-".repeat(widths.size)}  ${"-".repeat(widths.quant)}  ${"-".repeat(widths.type)}`,
  );
  let unknownCount = 0;
  for (const m of models) {
    const d = m.descriptor;
    if (d.family === "unknown") unknownCount++;
    console.log(
      `  ${pad(m.engineModelId, widths.id)}  ${pad(d.family, widths.family)}  ${pad(
        d.version ?? "—",
        widths.version,
      )}  ${pad(d.size, widths.size)}  ${pad(d.quant ?? "—", widths.quant)}  ${pad(d.type, widths.type)}`,
    );
  }
  console.log("");

  if (unknownCount > 0) {
    console.log(
      `⚠️  ${unknownCount} row(s) parsed family=unknown — paste the model id(s)`,
    );
    console.log(
      `   into a GitHub issue so we can extend the parser corpus.`,
    );
  } else {
    console.log("✅ Every cached model parsed cleanly.");
  }
  process.exit(0);
}

main().catch((err: unknown) => {
  const msg = err instanceof Error ? err.message : String(err);
  console.error(`smoke-ollama: ${msg}`);
  process.exit(1);
});
