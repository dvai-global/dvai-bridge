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
  console.log(`[DvAI] Initializing DvAI-Bridge in ./${publicDir}...`);

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
  const workerFiles = [
    'dvai-webllm.worker.js', 
    'dvai-transformers.worker.js',
    'dvai-native.worker.js' // Reserved for future native worker use if needed
  ];

  let copiedCount = 0;
  for (const file of workerFiles) {
    const src = path.join(distDir, file);
    const dest = path.join(process.cwd(), publicDir, file);

    if (fs.existsSync(src)) {
      // Ensure target directory exists
      if (!fs.existsSync(path.dirname(dest))) {
        fs.mkdirSync(path.dirname(dest), { recursive: true });
      }
      fs.copyFileSync(src, dest);
      console.log(`[DvAI] ✅ Copied ${file} to ${publicDir}/`);
      copiedCount++;
    }
  }

  if (copiedCount === 0) {
    console.warn(`[DvAI] ⚠️ No worker files found in ${distDir}.`);
    console.warn(`[DvAI] 💡 Please ensure the library is built or run "npm run prepare" in the dvai-bridge folder.`);
  }

  console.log('[DvAI] ✅ Setup complete! You can now use dvai-bridge in your project.');
} else {
  console.log(`
DvAI Edge CLI
Usage:
  dvai-bridge init [public-dir]    Initializes MSW service worker and copies
                                  AI inference workers (defaults to 'public')
  `);
}
