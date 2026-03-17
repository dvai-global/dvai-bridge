#!/usr/bin/env node
import { spawnSync } from 'child_process';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const args = process.argv.slice(2);
const command = args[0];

if (command === 'init') {
  const publicDir = args[1] || 'public';
  console.log(`[DvAI] Initializing DvAI-Edge in ./${publicDir}...`);

  // 1. Initialize MSW Service Worker
  console.log('[DvAI] Setting up MSW service worker...');
  const result = spawnSync('npx', ['msw', 'init', publicDir], {
    stdio: 'inherit',
    shell: true
  });

  if (result.status !== 0) {
    console.error('[DvAI] ❌ Failed to initialize MSW. Please ensure you have "msw" installed.');
    process.exit(1);
  }

  // 2. Copy worker files to public directory
  const distDir = path.resolve(__dirname, '..', 'dist');
  const workerFiles = ['dvai-webllm.worker.js', 'dvai-transformers.worker.js'];

  for (const file of workerFiles) {
    const src = path.join(distDir, file);
    const dest = path.join(publicDir, file);

    if (fs.existsSync(src)) {
      fs.copyFileSync(src, dest);
      console.log(`[DvAI] ✅ Copied ${file} to ${publicDir}/`);
    } else {
      console.warn(`[DvAI] ⚠️ Worker file not found: ${src}. Run "pnpm build" in dvai-edge-core first.`);
    }
  }

  console.log('[DvAI] ✅ Setup complete! You can now use dvai-edge in your project.');
} else {
  console.log(`
DvAI Edge CLI
Usage:
  dvai-edge init [public-dir]    Initializes MSW service worker and copies
                                  AI inference workers (defaults to 'public')
  `);
}
