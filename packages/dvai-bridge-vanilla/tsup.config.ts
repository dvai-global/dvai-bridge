import { builtinModules } from "node:module";
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
	// Browser/CDN package: resolve deps with the `browser` export condition
	// (msw 3 disables `msw/browser` under `node`).
	platform: "browser",
	// We don't mark dvai-bridge-core as external since it's used in IIFE bundle for CDN
	// but for ESM/CJS it might be better to keep it external.
	// For CDN usage, we typically want everything bundled.
	noExternal: ["@dvai-bridge/core"],
	esbuildOptions(options) {
		options.external = [
			"node-llama-cpp",
			"@reflink/reflink",
			"sharp",
			"onnxruntime-node",
			"@node-llama-cpp/*",
			// Node builtins referenced behind runtime guards (e.g. web-llm's `url`).
			...builtinModules,
			...builtinModules.map((m) => `node:${m}`),
		];
	},
});
