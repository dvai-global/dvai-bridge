import { describe, it, expect, vi, beforeEach } from "vitest";
import { DvAI } from "../index";

describe("DvAI Config and Defaults", () => {
	it("should use default config values", () => {
		const dvai = new DvAI();
		expect(dvai.modelId).toBe("gemma-2-2b-it-q4f16_1-MLC");
		expect(dvai.backend).toBe("webllm");
		expect(dvai.transformersModelId).toBe(
			"onnx-community/gemma-3n-E2B-it-ONNX",
		);
		expect(dvai.device).toBe("auto");
		expect(dvai.pipelineTask).toBe("text-generation");
		expect(dvai.generationTimeout).toBe(60000);
		expect(dvai.maxBlankChunks).toBe(20);
		expect(dvai.mockUrl).toBe("https://api.openai.local/v1/chat/completions");
		expect(dvai.serviceWorkerUrl).toBe("/mockServiceWorker.js");
		expect(dvai.webllmWorkerUrl).toBe("/dvai-webllm.worker.js");
		expect(dvai.transformersWorkerUrl).toBe("/dvai-transformers.worker.js");
		expect(dvai.isReady).toBe(false);
	});

	it("should apply custom config", () => {
		const dvai = new DvAI({
			modelId: "custom-model",
			backend: "transformers",
			transformersModelId: "custom-hf-model",
			pipelineTask: "text-to-image",
			device: "cpu",
			generationTimeout: 30000,
			maxBlankChunks: 5,
			mockUrl: "https://custom.mock/api",
			serviceWorkerUrl: "/custom-sw.js",
			webllmWorkerUrl: "/custom-webllm.js",
			transformersWorkerUrl: "/custom-transformers.js",
		});

		expect(dvai.modelId).toBe("custom-model");
		expect(dvai.backend).toBe("transformers");
		expect(dvai.transformersModelId).toBe("custom-hf-model");
		expect(dvai.pipelineTask).toBe("text-to-image");
		expect(dvai.device).toBe("cpu");
		expect(dvai.generationTimeout).toBe(30000);
		expect(dvai.maxBlankChunks).toBe(5);
		expect(dvai.mockUrl).toBe("https://custom.mock/api");
		expect(dvai.webllmWorkerUrl).toBe("/custom-webllm.js");
		expect(dvai.transformersWorkerUrl).toBe("/custom-transformers.js");
	});

	it("should return the active backend", () => {
		const dvai1 = new DvAI({ backend: "webllm" });
		expect(dvai1.getActiveBackend()).toBe("webllm");

		const dvai2 = new DvAI({ backend: "transformers" });
		expect(dvai2.getActiveBackend()).toBe("transformers");
	});

	it("should return null engine before initialization", () => {
		const dvai = new DvAI();
		expect(dvai.getEngine()).toBeNull();
		expect(dvai.getWorker()).toBeNull();
	});

	it("should throw on chatCompletion before initialization", async () => {
		const dvai = new DvAI();
		await expect(dvai.chatCompletion({ messages: [] })).rejects.toThrow(
			"Backend not initialized",
		);
	});

	it("should throw on runPipeline with webllm backend", async () => {
		const dvai = new DvAI({ backend: "webllm" });
		// Mock the backend as initialized but webllm
		(dvai as any).backendInstance = { run: () => {} };
		await expect(dvai.runPipeline("test input")).rejects.toThrow(
			"only available with the Transformers.js backend",
		);
	});
});
