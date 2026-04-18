import { defineConfig } from "tsup";

export default defineConfig({
	entry: ["src/index.ts"],
	format: ["esm", "cjs", "iife"],
	globalName: "VanillaDVAI",
	dts: true,
	splitting: false,
	sourcemap: true,
	clean: true,
	minify: true,
	bundle: true,
	// We don't mark dvai-bridge-core as external since it's used in IIFE bundle for CDN
	// but for ESM/CJS it might be better to keep it external.
	// For CDN usage, we typically want everything bundled.
	noExternal: ["@dvai-bridge/core"],
});
