/**
 * Example: Using dvai-bridge-core with LangChain.js
 * 
 * Since dvai-bridge-core automatically intercepts requests using MSW, 
 * you can use the standard `@langchain/openai` package completely unmodified.
 * Just point it to the tracked `mockUrl`.
 */

import { ChatOpenAI } from "@langchain/openai";
import { HumanMessage, SystemMessage } from "@langchain/core/messages";
import { dvai } from "@dvai-bridge/core";

export async function runLangChainExample() {
  // 1. Ensure the engine and worker are ready
  if (!dvai.isReady) {
    await dvai.initialize((progress) => console.log("Loading AI:", progress.text));
  }

  // 2. Setup standard LangChain
  const chat = new ChatOpenAI({
    modelName: dvai.modelId, // Auto-syncs with the loaded model
    apiKey: "local-bypass-key",
    maxTokens: 512,
    streaming: true, // WebLLM supports LangChain SSE streaming natively!
    configuration: {
      baseURL: dvai.mockUrl, // VERY IMPORTANT: Point to the URL MSW is intercepting
    },
  });

  // 3. Prompt the agent
  console.log("Sending prompt to local LangChain agent...");
  const stream = await chat.stream([
    new SystemMessage("You are a helpful local AI."),
    new HumanMessage("What is the capital of France?")
  ]);

  let fullResponse = "";
  for await (const chunk of stream) {
    fullResponse += chunk.content;
    console.log("Chunk received:", chunk.content);
  }

  console.log("Final Output:", fullResponse);
  return fullResponse;
}
