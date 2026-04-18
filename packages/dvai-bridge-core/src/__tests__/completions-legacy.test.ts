import { describe, it, expect } from "vitest";

describe("chatToLegacyCompletion", () => {
	it("converts chat.completion to text_completion shape", async () => {
		const { chatToLegacyCompletion } = await import("../index");
		const chatResp = {
			id: "chatcmpl-abc123",
			object: "chat.completion",
			created: 1000,
			model: "test-model",
			choices: [
				{
					index: 0,
					message: { role: "assistant", content: "Hello there!" },
					finish_reason: "stop",
				},
			],
			usage: { prompt_tokens: 5, completion_tokens: 3, total_tokens: 8 },
		};

		const legacy = chatToLegacyCompletion(chatResp);
		expect(legacy.object).toBe("text_completion");
		expect(legacy.id).toBe("cmpl-abc123");
		expect(legacy.created).toBe(1000);
		expect(legacy.model).toBe("test-model");
		expect(legacy.choices).toEqual([
			{
				text: "Hello there!",
				index: 0,
				finish_reason: "stop",
				logprobs: null,
			},
		]);
		expect(legacy.usage).toEqual({
			prompt_tokens: 5,
			completion_tokens: 3,
			total_tokens: 8,
		});
	});

	it("handles missing fields gracefully", async () => {
		const { chatToLegacyCompletion } = await import("../index");
		const legacy = chatToLegacyCompletion({});
		expect(legacy.object).toBe("text_completion");
		expect(legacy.choices).toEqual([]);
		expect(legacy.usage).toBeDefined();
	});
});

describe("legacyCompletionStreamAdapter", () => {
	async function collectStream(stream: ReadableStream<Uint8Array>): Promise<string> {
		const reader = stream.getReader();
		const decoder = new TextDecoder();
		let out = "";
		while (true) {
			const { done, value } = await reader.read();
			if (done) break;
			out += decoder.decode(value);
		}
		return out;
	}

	function sseStream(events: string[]): ReadableStream<Uint8Array> {
		const encoder = new TextEncoder();
		let i = 0;
		return new ReadableStream({
			pull(controller) {
				if (i >= events.length) {
					controller.close();
					return;
				}
				controller.enqueue(encoder.encode(events[i]));
				i++;
			},
		});
	}

	it("rewrites chat.completion.chunk events as text_completion.chunk", async () => {
		const { legacyCompletionStreamAdapter } = await import("../index");

		const chatEvents = [
			`data: ${JSON.stringify({
				id: "chatcmpl-1",
				object: "chat.completion.chunk",
				created: 1,
				model: "m",
				choices: [{ index: 0, delta: { content: "Hel" }, finish_reason: null }],
			})}\n\n`,
			`data: ${JSON.stringify({
				id: "chatcmpl-1",
				object: "chat.completion.chunk",
				created: 1,
				model: "m",
				choices: [{ index: 0, delta: { content: "lo" }, finish_reason: null }],
			})}\n\n`,
			`data: ${JSON.stringify({
				id: "chatcmpl-1",
				object: "chat.completion.chunk",
				created: 1,
				model: "m",
				choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
			})}\n\n`,
			`data: [DONE]\n\n`,
		];

		const legacy = legacyCompletionStreamAdapter(sseStream(chatEvents), "m");
		const out = await collectStream(legacy);

		expect(out).toContain('"object":"text_completion.chunk"');
		expect(out).toContain('"text":"Hel"');
		expect(out).toContain('"text":"lo"');
		expect(out).toContain('"id":"cmpl-1"');
		expect(out).toContain('"finish_reason":"stop"');
		expect(out).toContain("data: [DONE]\n\n");
		expect(out).not.toContain("chat.completion.chunk");
	});

	it("forwards raw payloads that cannot be parsed as JSON", async () => {
		const { legacyCompletionStreamAdapter } = await import("../index");
		const chatEvents = [`data: not-json\n\n`, `data: [DONE]\n\n`];
		const legacy = legacyCompletionStreamAdapter(sseStream(chatEvents), "m");
		const out = await collectStream(legacy);
		expect(out).toContain("data: not-json\n\n");
		expect(out).toContain("data: [DONE]\n\n");
	});
});
