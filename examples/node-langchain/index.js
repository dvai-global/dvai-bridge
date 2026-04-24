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

  await dvai.initialize((progress) =>
    console.log(`Loading model: ${progress.text ?? ""}`),
  );

  console.log(`[dvai] Local server ready at ${dvai.baseUrl}`);

  const chat = new ChatOpenAI({
    modelName: dvai.getActiveBackend() === "transformers" ? dvai.transformersModelId : dvai.modelId,
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

  await dvai.unload();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
