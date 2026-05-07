import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri 2 dev workflow:
//   - tauri runs `pnpm dev:vite` to bring up the dev server
//   - the Rust shell loads `http://localhost:5173`
//   - on `pnpm build:vite`, output lands in `dist-frontend/`
//     which is the `frontendDist` configured in `tauri.conf.json`.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: {
    port: 5173,
    strictPort: true,
    // Don't open a browser; Tauri owns the window.
    open: false,
  },
  build: {
    outDir: "dist-frontend",
    target: "es2022",
    sourcemap: true,
  },
  envPrefix: ["VITE_", "TAURI_"],
});
