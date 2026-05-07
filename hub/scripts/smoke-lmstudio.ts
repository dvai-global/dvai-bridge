/**
 * Phase 4 smoke test — LMStudioAdapter against a real `localhost:1234`.
 *
 * Run after `pnpm build:peer-mode`:
 *   node dist/scripts/smoke-lmstudio.js
 *
 * Optional env:
 *   LMSTUDIO_BASE_URL          override base URL (default http://127.0.0.1:1234)
 *   LMSTUDIO_USE_SUBPROCESS=1  use `lms ls` instead of /v1/models
 */

import { LMStudioAdapter } from "../peer-mode/adapters/LMStudioAdapter.js";

async function main(): Promise<void> {
  const baseUrl = process.env.LMSTUDIO_BASE_URL;
  const useSubprocess = process.env.LMSTUDIO_USE_SUBPROCESS === "1";
  const adapter = new LMStudioAdapter({
    ...(baseUrl !== undefined ? { baseUrl } : {}),
    useSubprocessEnumeration: useSubprocess,
  });

  console.log("→ LM Studio adapter smoke test");
  console.log(`  baseUrl: ${baseUrl ?? "http://127.0.0.1:1234"}`);
  console.log(`  enumeration path: ${useSubprocess ? "lms ls (subprocess)" : "/v1/models (HTTP)"}`);
  console.log("");

  const detected = await adapter.detect();
  console.log(`detect(): ${detected ? "✅ true" : "❌ false"}`);
  if (!detected) {
    console.log("");
    console.log("LM Studio's local server is not reachable.");
    console.log("In LM Studio: Settings → Local Server → Start server, then re-run.");
    process.exit(1);
  }

  const models = await adapter.enumerateCachedModels();
  console.log(`enumerateCachedModels(): ${models.length} row(s)`);
  console.log("");

  if (models.length === 0) {
    console.log("LM Studio is reachable but no models are loaded. Load one in");
    console.log("LM Studio's Chat tab (model picker → My Models) and re-run.");
    process.exit(0);
  }

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
    console.log("✅ Every loaded model parsed cleanly.");
  }
  process.exit(0);
}

main().catch((err: unknown) => {
  const msg = err instanceof Error ? err.message : String(err);
  console.error(`smoke-lmstudio: ${msg}`);
  process.exit(1);
});
