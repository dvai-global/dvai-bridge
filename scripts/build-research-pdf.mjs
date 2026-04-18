// One-shot converter: RESEARCH.md → RESEARCH.html → RESEARCH.pdf
// Uses `marked` for HTML rendering and the system Chrome for PDF printing.
//
// `marked` is not a committed devDependency — it's only needed to produce
// the research artifact. This script installs it on demand, runs the build,
// and removes it again on the way out (but only if it installed it itself;
// if marked was already present, it is left alone).

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const IS_WIN = process.platform === "win32";
const pnpm = (args) =>
  execFileSync("pnpm", args, { stdio: "inherit", shell: IS_WIN });

let installedMarkedHere = false;
let marked;
try {
  ({ marked } = await import("marked"));
} catch {
  console.log("[build-research-pdf] Installing marked temporarily...");
  pnpm(["add", "-D", "-w", "marked"]);
  installedMarkedHere = true;
  ({ marked } = await import("marked"));
}

try {
  await main();
} finally {
  if (installedMarkedHere) {
    console.log("[build-research-pdf] Removing marked (installed for this run only)...");
    try {
      pnpm(["remove", "-w", "marked"]);
    } catch (e) {
      console.warn(
        "[build-research-pdf] pnpm remove failed; marked may still be installed.",
        e?.message ?? e,
      );
    }
  }
}

async function main() {

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..");
const mdPath = resolve(repoRoot, "RESEARCH.md");
const htmlPath = resolve(repoRoot, "RESEARCH.html");
const pdfPath = resolve(repoRoot, "RESEARCH.pdf");

if (!existsSync(mdPath)) {
  throw new Error(`[build-research-pdf] Not found: ${mdPath}`);
}

const md = readFileSync(mdPath, "utf8");
const body = marked.parse(md, { gfm: true, breaks: true });

const css = `
  @page { size: A4; margin: 22mm 20mm 22mm 20mm; }
  :root { --ink: #111827; --muted: #4B5563; --rule: #D1D5DB; --accent: #1E3A8A; --code-bg: #F3F4F6; }
  * { box-sizing: border-box; }
  html, body { background: #ffffff; color: var(--ink); }
  body {
    font-family: "Charter", "Georgia", "Iowan Old Style", "Palatino Linotype", "Cambria", serif;
    font-size: 11pt;
    line-height: 1.55;
    max-width: 175mm;
    margin: 0 auto;
    padding: 0;
    -webkit-print-color-adjust: exact;
    print-color-adjust: exact;
  }
  h1, h2, h3, h4 {
    font-family: "Inter", "Segoe UI", "Helvetica Neue", Arial, sans-serif;
    color: var(--ink);
    line-height: 1.25;
    page-break-after: avoid;
  }
  h1 { font-size: 22pt; margin: 0 0 6pt; letter-spacing: -0.01em; }
  h2 { font-size: 14pt; margin: 22pt 0 8pt; padding-top: 6pt; border-top: 1px solid var(--rule); }
  h3 { font-size: 12pt; margin: 16pt 0 6pt; color: var(--accent); }
  h4 { font-size: 11pt; margin: 12pt 0 4pt; }
  p { margin: 0 0 8pt; text-align: justify; hyphens: auto; }
  strong { color: var(--ink); }
  em { color: var(--ink); }
  ul, ol { margin: 0 0 10pt; padding-left: 22pt; }
  li { margin-bottom: 3pt; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  code {
    font-family: "JetBrains Mono", "Fira Code", "SFMono-Regular", Consolas, "Liberation Mono", monospace;
    font-size: 9.5pt;
    background: var(--code-bg);
    padding: 1px 4px;
    border-radius: 3px;
  }
  pre {
    background: var(--code-bg);
    border: 1px solid var(--rule);
    border-radius: 5px;
    padding: 10pt 12pt;
    overflow-x: auto;
    font-size: 9pt;
    line-height: 1.45;
    page-break-inside: avoid;
  }
  pre code { background: transparent; padding: 0; font-size: inherit; }
  table {
    border-collapse: collapse;
    width: 100%;
    margin: 8pt 0 14pt;
    font-size: 10pt;
    page-break-inside: avoid;
  }
  th, td {
    border: 1px solid var(--rule);
    padding: 6pt 8pt;
    text-align: left;
    vertical-align: top;
  }
  th { background: #F9FAFB; font-family: "Inter", "Segoe UI", Arial, sans-serif; }
  hr { border: 0; border-top: 1px solid var(--rule); margin: 20pt 0; }
  blockquote {
    margin: 8pt 0;
    padding: 4pt 12pt;
    border-left: 3px solid var(--accent);
    color: var(--muted);
  }
  img, svg { max-width: 100%; height: auto; display: block; margin: 12pt auto; page-break-inside: avoid; }
  p > img { margin: 12pt auto; }
  /* Title block: treat the first h1 + the first plain paragraphs as the cover header */
  h1 + p { font-size: 10pt; color: var(--muted); margin-bottom: 12pt; }
`;

const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>DVAI-BRIDGE — Research Paper</title>
  <base href="${pathToFileURL(repoRoot).href}/" />
  <style>${css}</style>
</head>
<body>
${body}
</body>
</html>`;

writeFileSync(htmlPath, html, "utf8");
console.log(`[build-research-pdf] Wrote ${htmlPath}`);

// Find Chrome
const candidates = [
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const chrome = candidates.find(existsSync);
if (!chrome) {
  throw new Error(
    "[build-research-pdf] No Chrome/Edge found in standard locations.",
  );
}
console.log(`[build-research-pdf] Using ${chrome}`);

const fileUrl = pathToFileURL(htmlPath).href;
const args = [
  "--headless=new",
  "--disable-gpu",
  "--no-pdf-header-footer",
  "--no-sandbox",
  "--virtual-time-budget=10000",
  `--print-to-pdf=${pdfPath}`,
  fileUrl,
];

try {
  execFileSync(chrome, args, { stdio: "inherit" });
} catch (err) {
  throw new Error(
    `[build-research-pdf] Chrome print failed: ${err.message}`,
  );
}

console.log(`[build-research-pdf] Wrote ${pdfPath}`);
}

