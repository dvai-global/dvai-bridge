import { defineConfig } from 'tsup';

export default defineConfig({
  entry: ['src/index.ts'],
  format: ['esm', 'cjs', 'iife'],
  globalName: 'VanillaDvAI',
  dts: true,
  splitting: false,
  sourcemap: true,
  clean: true,
  minify: true,
  bundle: true,
  // We don't mark dvai-edge-core as external since it's used in IIFE bundle for CDN
  // but for ESM/CJS it might be better to keep it external. 
  // For CDN usage, we typically want everything bundled.
  noExternal: ['@dvai-edge/core'],
});
