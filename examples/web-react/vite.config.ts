import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  define: {
    global: 'globalThis',
    'process.env': {},
  },
  resolve: {
    alias: {
      'langchain': path.resolve(__dirname, 'node_modules/langchain/dist/index.js'),
    },
    conditions: ['import', 'module', 'browser', 'development'],
  },
  optimizeDeps: {
    include: ['langchain', '@langchain/core', '@langchain/openai'],
  },
  build: {
    rollupOptions: {
      external: [
        'node-llama-cpp',
        '@reflink/reflink',
        'sharp',
        'onnxruntime-node',
        'multicast-dns',
        'dns-txt',
      ],
    },
  },
})
