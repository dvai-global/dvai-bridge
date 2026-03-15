#!/usr/bin/env node
import { spawnSync } from 'child_process';
import path from 'path';
import fs from 'fs';

const args = process.argv.slice(2);
const command = args[0];

if (command === 'init') {
  const publicDir = args[1] || 'public';
  console.log(`[DvAI] Initializing MSW service worker in ./${publicDir}...`);
  
  const result = spawnSync('npx', ['msw', 'init', publicDir], {
    stdio: 'inherit',
    shell: true
  });

  if (result.status === 0) {
    console.log('[DvAI] ✅ Setup complete! You can now use dvai-edge in your project.');
  } else {
    console.error('[DvAI] ❌ Failed to initialize MSW. Please ensure you have "msw" installed and specified the correct public directory.');
  }
} else {
  console.log(`
DvAI Edge CLI
Usage:
  dvai-edge init [public-dir]    Initializes the MSW service worker (defaults to 'public')
  `);
}
