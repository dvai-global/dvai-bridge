// Builds the Capacitor app's `www/` bundle.
//
// 1. esbuild bundles `src/main.js` -> `www/main.js`, inlining the
//    `@dvai-bridge/capacitor` dependency from the workspace.
// 2. `src/index.html` and `src/styles.css` are copied verbatim into `www/`.
//
// The native plugins (capacitor-llama et al.) are linked at `cap sync` time
// from `node_modules/@dvai-bridge/*` — they don't go through the bundler.

import { build } from "esbuild";
import { mkdir, copyFile, rm } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const src = join(root, "src");
const out = join(root, "www");

async function main() {
  await rm(out, { recursive: true, force: true });
  await mkdir(out, { recursive: true });

  await build({
    entryPoints: [join(src, "main.js")],
    bundle: true,
    format: "esm",
    target: ["es2022"],
    outfile: join(out, "main.js"),
    sourcemap: false,
    logLevel: "info",
  });

  await copyFile(join(src, "index.html"), join(out, "index.html"));
  await copyFile(join(src, "styles.css"), join(out, "styles.css"));
  console.log("[capacitor-mobile] www/ built.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
