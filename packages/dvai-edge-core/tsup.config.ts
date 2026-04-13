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
    platform: 'browser',
    target: 'es2020',
    define: {
      'process.env.NODE_ENV': '"production"',
    },
    treeshake: true,
    esbuildOptions(options) {
      // Force browser entry points for packages with conditional exports.
      // Without this, tsup/esbuild may resolve to the Node.js entry
      // (e.g. transformers.node.mjs) which pulls in sharp, fs, child_process
      // — all of which crash inside a browser Web Worker.
      options.conditions = ['browser', 'import', 'default'];
      options.mainFields = ['browser', 'module', 'main'];

      // Externalize Node.js builtins and native modules that must not
      // appear in a browser bundle.
      options.external = [
        'fs', 'path', 'child_process', 'crypto', 'http', 'https',
        'os', 'url', 'stream', 'events', 'util', 'assert', 'buffer',
        'zlib', 'net', 'tls', 'dns', 'worker_threads',
        'sharp', 'sharp/*',
        'onnxruntime-node',
        'node-fetch',
        'node:*',
      ];
    }
  },
]);
