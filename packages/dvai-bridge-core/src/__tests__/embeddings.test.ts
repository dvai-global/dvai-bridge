import { describe, it, expect, vi } from "vitest";

describe("TransformersBackend embeddings", () => {
	it("throws when called on a non-feature-extraction task", async () => {
		const { TransformersBackend } = await import("../TransformersBackend");
		const backend = new TransformersBackend({
			modelId: "test-model",
			device: "cpu",
			generationTimeout: 5000,
			pipelineTask: "text-generation",
		});
		(backend as any).pipeline = vi.fn();
		await expect(backend.embedding("hello")).rejects.toThrow(
			'requires pipelineTask="feature-extraction"',
		);
	});

	it("returns embeddings array from feature-extraction pipeline (plain array)", async () => {
		const { TransformersBackend } = await import("../TransformersBackend");
		const backend = new TransformersBackend({
			modelId: "test-model",
			device: "cpu",
			generationTimeout: 5000,
			pipelineTask: "feature-extraction",
		});
		const mockVec = [0.1, 0.2, 0.3];
		(backend as any).pipeline = vi.fn().mockResolvedValue([mockVec, mockVec]);

		const result = await backend.embedding(["a", "b"]);
		expect(result).toEqual([mockVec, mockVec]);
		expect((backend as any).pipeline).toHaveBeenCalledWith(["a", "b"], {
			pooling: "mean",
			normalize: true,
		});
	});

	it("handles Tensor output with .tolist()", async () => {
		const { TransformersBackend } = await import("../TransformersBackend");
		const backend = new TransformersBackend({
			modelId: "test-model",
			device: "cpu",
			generationTimeout: 5000,
			pipelineTask: "feature-extraction",
		});
		const tensor = {
			tolist: () => [
				[0.1, 0.2],
				[0.3, 0.4],
			],
		};
		(backend as any).pipeline = vi.fn().mockResolvedValue(tensor);

		const result = await backend.embedding(["a", "b"]);
		expect(result).toEqual([
			[0.1, 0.2],
			[0.3, 0.4],
		]);
	});

	it("handles Tensor output with .data and .dims", async () => {
		const { TransformersBackend } = await import("../TransformersBackend");
		const backend = new TransformersBackend({
			modelId: "test-model",
			device: "cpu",
			generationTimeout: 5000,
			pipelineTask: "feature-extraction",
		});
		const tensor = {
			data: new Float32Array([0.1, 0.2, 0.3, 0.4]),
			dims: [2, 2],
		};
		(backend as any).pipeline = vi.fn().mockResolvedValue(tensor);

		const result = await backend.embedding(["a", "b"]);
		expect(result).toHaveLength(2);
		expect(result[0]).toHaveLength(2);
		expect(result[0][0]).toBeCloseTo(0.1);
		expect(result[1][1]).toBeCloseTo(0.4);
	});

	it("accepts single string input and returns array of vectors", async () => {
		const { TransformersBackend } = await import("../TransformersBackend");
		const backend = new TransformersBackend({
			modelId: "test-model",
			device: "cpu",
			generationTimeout: 5000,
			pipelineTask: "feature-extraction",
		});
		(backend as any).pipeline = vi.fn().mockResolvedValue([[0.1, 0.2]]);

		const result = await backend.embedding("single input");
		expect(result).toEqual([[0.1, 0.2]]);
		expect((backend as any).pipeline).toHaveBeenCalledWith(["single input"], {
			pooling: "mean",
			normalize: true,
		});
	});
});

describe("NativeBackend embeddings", () => {
	it("throws when embeddingMode is false", async () => {
		const { NativeBackend } = await import("../NativeBackend");
		const backend = new NativeBackend({
			modelPath: "/model.gguf",
			embeddingMode: false,
		});
		(backend as any).context = { embedding: vi.fn() };
		await expect(backend.embedding("text")).rejects.toThrow(
			"embeddingMode: true",
		);
	});

	it("throws when context has no embedding() method", async () => {
		const { NativeBackend } = await import("../NativeBackend");
		const backend = new NativeBackend({
			modelPath: "/model.gguf",
			embeddingMode: true,
		});
		(backend as any).context = {};
		await expect(backend.embedding("text")).rejects.toThrow(
			"does not expose an embedding()",
		);
	});

	it("calls context.embedding() for each input and unwraps {embedding: [...]}", async () => {
		const { NativeBackend } = await import("../NativeBackend");
		const backend = new NativeBackend({
			modelPath: "/model.gguf",
			embeddingMode: true,
		});
		const mockContext = {
			embedding: vi
				.fn()
				.mockResolvedValueOnce({ embedding: [0.1, 0.2] })
				.mockResolvedValueOnce({ embedding: [0.3, 0.4] }),
		};
		(backend as any).context = mockContext;

		const result = await backend.embedding(["a", "b"]);
		expect(result).toEqual([
			[0.1, 0.2],
			[0.3, 0.4],
		]);
		expect(mockContext.embedding).toHaveBeenCalledTimes(2);
		expect(mockContext.embedding).toHaveBeenNthCalledWith(1, "a");
		expect(mockContext.embedding).toHaveBeenNthCalledWith(2, "b");
	});

	it("accepts raw array return from context.embedding()", async () => {
		const { NativeBackend } = await import("../NativeBackend");
		const backend = new NativeBackend({
			modelPath: "/model.gguf",
			embeddingMode: true,
		});
		(backend as any).context = {
			embedding: vi.fn().mockResolvedValue([0.5, 0.6, 0.7]),
		};

		const result = await backend.embedding("single");
		expect(result).toEqual([[0.5, 0.6, 0.7]]);
	});
});

describe("DVAI.embedding gating", () => {
	it("throws when backend is webllm", async () => {
		const { DVAI } = await import("../index");
		const dvai = new DVAI({ backend: "webllm" });
		(dvai as any).backendInstance = { embedding: vi.fn() };
		await expect(dvai.embedding("hi")).rejects.toThrow(
			"not supported on the WebLLM backend",
		);
	});

	it("throws when backend is not initialized", async () => {
		const { DVAI } = await import("../index");
		const dvai = new DVAI({ backend: "transformers" });
		await expect(dvai.embedding("hi")).rejects.toThrow("not initialized");
	});

	it("delegates to backendInstance.embedding on transformers backend", async () => {
		const { DVAI } = await import("../index");
		const dvai = new DVAI({ backend: "transformers" });
		const vectors = [[0.1, 0.2]];
		(dvai as any).backendInstance = {
			embedding: vi.fn().mockResolvedValue(vectors),
		};
		const result = await dvai.embedding("hi");
		expect(result).toBe(vectors);
	});

	it("throws if backend has no embedding method (e.g. custom)", async () => {
		const { DVAI } = await import("../index");
		const dvai = new DVAI({ backend: "transformers" });
		(dvai as any).backendInstance = {};
		await expect(dvai.embedding("hi")).rejects.toThrow(
			"does not expose an embedding()",
		);
	});
});
