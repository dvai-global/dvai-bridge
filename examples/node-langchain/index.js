/**
 * Node + LangChain + dvai-bridge example.
 *
 * dvai-bridge starts a local OpenAI-compatible HTTP server on 127.0.0.1
 * and routes requests to a local Transformers.js model. Point LangChain's
 * ChatOpenAI at `dvai.baseUrl` and everything else stays standard.
 */
import { ChatOpenAI } from "@langchain/openai";
import { HumanMessage, SystemMessage } from "@langchain/core/messages";
import { DVAI } from "@dvai-bridge/core";

async function main() {
  const dvai = new DVAI({
    backend: "transformers",
    transformersModelId: "onnx-community/gemma-3n-E2B-it-ONNX",
  });

  await dvai.initialize((progress) => {
    if (progress?.text) console.log(`Loading model: ${progress.text}`);
  });

  console.log(`[dvai] Local server ready at ${dvai.baseUrl}`);

  try {
    const chat = new ChatOpenAI({
      modelName: dvai.transformersModelId,
      apiKey: "local-bypass-key",
      maxTokens: 256,
      streaming: true,
      configuration: { baseURL: dvai.baseUrl },
    });

    const stream = await chat.stream([
      new SystemMessage("You are a helpful local AI."),
      new HumanMessage("What is the capital of France?"),
    ]);

    for await (const chunk of stream) {
      process.stdout.write(String(chunk.content));
    }
    console.log();
  } finally {
    // Always release the local server + model, even on error —
    // important for long-lived processes that reuse this pattern.
    await dvai.unload();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
