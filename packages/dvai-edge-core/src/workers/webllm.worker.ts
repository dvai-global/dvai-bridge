/**
 * WebLLM Web Worker Entry Point
 * This file runs inside a Web Worker and handles all WebLLM inference
 * to keep the main thread unblocked.
 *
 * Deploy this file to your public directory via `dvai-edge init`.
 */
import { WebWorkerMLCEngineHandler } from "@mlc-ai/web-llm";

const handler = new WebWorkerMLCEngineHandler();

self.onmessage = (msg: MessageEvent) => {
  handler.onmessage(msg);
};
