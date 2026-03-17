import { defineConfig } from 'tsup';

export default defineConfig([
  // Main library bundle
  {
    entry: ['src/index.ts'],
    format: ['esm', 'cjs'],
    dts: true,
    splitting: false,
    sourcemap: true,
    clean: true,
    minify: true,
  },
  // Worker bundles (deployed to public dir via CLI)
  {
    entry: {
      'dvai-webllm.worker': 'src/workers/webllm.worker.ts',
      'dvai-transformers.worker': 'src/workers/transformers.worker.ts',
    },
    format: ['esm'],
    splitting: false,
    sourcemap: false,
    clean: false,
    minify: true,
    noExternal: [/.*/], // Bundle all dependencies into workers
  },
]);
