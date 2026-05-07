/**
 * Node + node-llama-cpp + dvai-bridge example.
 *
 * Uses the new `backend: "native"` path on @dvai-bridge/core (added in
 * Phase 2 Task 1). dvai-bridge wraps node-llama-cpp's LlamaChatSession
 * behind the same OpenAI-compatible HTTP server it ships for the
 * Transformers.js backend, so LangChain's ChatOpenAI works unchanged —
 * point it at `dvai.baseUrl` and stream.
 *
 * Model: bartowski/Llama-3.2-1B-Instruct-GGUF (Q4_K_M, ~800 MB).
 * On first run, scripts/download-model.js fetches the GGUF into
 * examples/node-llama-cpp/models/ — idempotent, can be invoked separately:
 *
 *     pnpm --filter node-llama-cpp download-model
 */
import { ChatOpenAI } from "@langchain/openai";
import { HumanMessage, SystemMessage } from "@langchain/core/messages";
import { DVAI } from "@dvai-bridge/core";
import { ensureModel } from "./scripts/download-model.js";

async function main() {
	const modelPath = await ensureModel();

	const dvai = new DVAI({
		backend: "native",
		nativeModelPath: modelPath,
		nativeContextSize: 2048,
		// gpuLayers defaults to 99 (Metal/CUDA off-load); CPU fallback works
		// when no accelerator is available.
		generationTimeout: 120_000,
	});

	await dvai.initialize((progress) => {
		if (progress?.text) console.log(`[dvai] ${progress.text}`);
	});

	console.log(`[dvai] Local server ready at ${dvai.baseUrl}`);

	try {
		const chat = new ChatOpenAI({
			modelName: "Llama-3.2-1B-Instruct-Q4_K_M",
			apiKey: "local-bypass-key",
			maxTokens: 96,
			streaming: true,
			configuration: { baseURL: dvai.baseUrl },
		});

		const stream = await chat.stream([
			new SystemMessage("You are a helpful local AI."),
			new HumanMessage("Say hello in one short sentence."),
		]);

		let received = "";
		for await (const chunk of stream) {
			const text = String(chunk.content);
			received += text;
			process.stdout.write(text);
		}
		console.log();

		if (!received.trim()) {
			throw new Error("Empty completion received from native backend.");
		}
	} finally {
		// Always release the local server + model, even on error.
		await dvai.unload();
	}
}

main().catch((err) => {
	console.error(err);
	process.exit(1);
});
