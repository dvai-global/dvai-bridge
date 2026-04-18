/**
 * Example: Using dvai-bridge-core with LangChain.js
 *
 * dvai-bridge-core intercepts OpenAI API calls via MSW, so you can use
 * the standard `@langchain/openai` package completely unmodified —
 * just point `baseURL` at the intercepted base URL.
 *
 * Streaming now uses real token-level streaming when backend is
 * "transformers" or "native"; WebLLM has always streamed natively.
 */

import { ChatOpenAI } from "@langchain/openai";
import { HumanMessage, SystemMessage } from "@langchain/core/messages";
import { DvAI } from "@dvai-bridge/core";

export async function runLangChainExample() {
	// 1. Initialize the engine + MSW interceptors
	const dvai = new DvAI({
		backend: "webllm", // or "transformers" / "native"
		// ...other config as needed
	});
	await dvai.initialize((progress) =>
		console.log("Loading AI:", progress.text),
	);

	// 2. Derive the base URL from dvai.mockUrl (which points at /v1/chat/completions).
	//    LangChain / OpenAI SDK append "/chat/completions" themselves, so we strip it.
	const baseURL = dvai.mockUrl.replace(/\/chat\/completions$/, "");

	const chat = new ChatOpenAI({
		modelName: dvai.modelId,
		apiKey: "local-bypass-key",
		maxTokens: 512,
		streaming: true,
		configuration: { baseURL },
	});

	// 3. Stream tokens
	console.log("Sending prompt to local LangChain agent...");
	const stream = await chat.stream([
		new SystemMessage("You are a helpful local AI."),
		new HumanMessage("What is the capital of France?"),
	]);

	let fullResponse = "";
	for await (const chunk of stream) {
		fullResponse += chunk.content;
		process.stdout.write(String(chunk.content));
	}
	console.log();

	console.log("Final Output:", fullResponse);
	return fullResponse;
}
