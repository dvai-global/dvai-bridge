import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');
const packagesDir = path.resolve(rootDir, 'packages');
const metaFiles = ['README.md', 'LICENSE'];

for (const file of metaFiles) {
  const src = path.join(rootDir, file);
  if (!fs.existsSync(src)) {
    console.error(`Missing ${file} at repo root; skipping.`);
    process.exit(1);
  }
}

console.log('Syncing README.md and LICENSE to all packages...');

const packages = fs.readdirSync(packagesDir);

for (const pkgName of packages) {
  const pkgDir = path.join(packagesDir, pkgName);
  if (!fs.statSync(pkgDir).isDirectory()) continue;
  if (!fs.existsSync(path.join(pkgDir, 'package.json'))) continue;

  for (const file of metaFiles) {
    fs.copyFileSync(path.join(rootDir, file), path.join(pkgDir, file));
  }
  console.log(`- Updated ${pkgName}`);
}

console.log('Package metadata synchronization complete.');
