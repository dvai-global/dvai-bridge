#!/usr/bin/env node
/**
 * Bundle the Hub's Node sidecar into a single-file native binary that
 * Tauri can ship via `externalBin`.
 *
 * Strategy:
 *   1. Detect host platform → rustc target triple naming Tauri uses.
 *   2. Run `bun build --compile` against `dist/peer-mode/server.js`,
 *      output to `src-tauri/binaries/dvai-hub-peer-mode-<triple>.<ext>`.
 *   3. If Bun isn't on PATH, exit 0 with a warning so dev `pnpm tauri
 *      dev` still works (sidecar.rs's dev path spawns `node …` instead).
 *      Production builds (CI) install Bun first via the matching
 *      step in `.github/workflows/dvai-hub-release.yml`.
 *
 * Run from `hub/`:
 *   pnpm bundle:sidecar
 */

import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HUB_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const SIDECAR_SRC = join(HUB_ROOT, "dist", "peer-mode", "server.js");
const OUT_DIR = join(HUB_ROOT, "src-tauri", "binaries");

/** Map host (Node `process.platform`/`process.arch`) → rustc target triple. */
function targetTriple() {
  const p = process.platform;
  const a = process.arch;
  if (p === "win32" && a === "x64") return "x86_64-pc-windows-msvc";
  if (p === "win32" && a === "arm64") return "aarch64-pc-windows-msvc";
  if (p === "darwin" && a === "x64") return "x86_64-apple-darwin";
  if (p === "darwin" && a === "arm64") return "aarch64-apple-darwin";
  if (p === "linux" && a === "x64") return "x86_64-unknown-linux-gnu";
  if (p === "linux" && a === "arm64") return "aarch64-unknown-linux-gnu";
  throw new Error(`unsupported host: platform=${p} arch=${a}`);
}

/** Bun's `--target` flag uses a different naming. Map it. */
function bunTarget() {
  const p = process.platform;
  const a = process.arch;
  if (p === "win32" && a === "x64") return "bun-windows-x64";
  if (p === "darwin" && a === "x64") return "bun-darwin-x64";
  if (p === "darwin" && a === "arm64") return "bun-darwin-arm64";
  if (p === "linux" && a === "x64") return "bun-linux-x64";
  if (p === "linux" && a === "arm64") return "bun-linux-arm64";
  throw new Error(`bun --compile target unmapped for ${p}/${a}`);
}

function isBunInstalled() {
  const r = spawnSync("bun", ["--version"], {
    stdio: "ignore",
    shell: process.platform === "win32",
  });
  return r.status === 0;
}

function main() {
  if (!existsSync(SIDECAR_SRC)) {
    console.error(
      `[bundle:sidecar] missing input: ${SIDECAR_SRC}\n` +
        `Run \`pnpm build:peer-mode\` first.`,
    );
    process.exit(1);
  }
  const triple = targetTriple();
  const ext = process.platform === "win32" ? ".exe" : "";
  const out = join(OUT_DIR, `dvai-hub-peer-mode-${triple}${ext}`);
  if (!existsSync(OUT_DIR)) mkdirSync(OUT_DIR, { recursive: true });

  if (!isBunInstalled()) {
    // Bun absent — write a placeholder file so Tauri's `externalBin`
    // compile-time validation passes for `tauri dev` / `cargo check`.
    // The runtime spawn in `src-tauri/src/sidecar.rs` checks for the
    // binary at the resource path (NOT this dev-side path) and falls
    // back to `node dist/peer-mode/server.js` if absent — so the
    // placeholder is never actually executed.
    writeFileSync(out, "# bundle:sidecar placeholder — Bun not installed.\n");
    console.warn(
      `[bundle:sidecar] Bun not on PATH — wrote a placeholder at ${out}.\n` +
        "   Dev mode (`pnpm tauri dev`) still works; the Rust sidecar.rs\n" +
        "   falls back to spawning `node dist/peer-mode/server.js` because\n" +
        "   the placeholder isn't packaged into the production resource_dir.\n" +
        "   To produce a real bundled binary, install Bun:\n" +
        "     curl -fsSL https://bun.com/install | bash       (Linux/macOS)\n" +
        "     irm bun.com/install.ps1 | iex                   (Windows)",
    );
    return;
  }

  console.log(`[bundle:sidecar] target: ${triple}`);
  console.log(`[bundle:sidecar] input:  ${SIDECAR_SRC}`);
  console.log(`[bundle:sidecar] output: ${out}`);

  // bun build --compile bundles the script + all imports + the Bun
  // runtime into a single executable. Native deps (onnxruntime-node,
  // node-llama-cpp, sharp) ship as .node files alongside; bun resolves
  // them at runtime. For pure-JS deps, everything is inside the
  // resulting binary.
  execFileSync(
    "bun",
    [
      "build",
      "--compile",
      "--minify",
      "--sourcemap",
      `--target=${bunTarget()}`,
      SIDECAR_SRC,
      "--outfile",
      out,
    ],
    {
      stdio: "inherit",
      shell: process.platform === "win32",
    },
  );

  const sizeMb = (statSync(out).size / 1024 / 1024).toFixed(1);
  console.log(`[bundle:sidecar] ✓ produced ${out} (${sizeMb} MB)`);
}

main();
