/**
 * LiteRTLMBackend: Wraps @litert-lm/core (Google's LiteRT-LM web runtime)
 * behind the same OpenAI HTTP surface as our WebLLM and Transformers.js
 * backends. WebGPU inference in the browser; the runtime handles worker
 * offloading internally so we don't spawn one ourselves.
 *
 * Design notes:
 * - @litert-lm/core exposes a stateful Conversation API
 *   (createConversation → sendMessage / sendMessageStreaming). To fit
 *   OpenAI's stateless /v1/chat/completions surface we create a fresh
 *   conversation per request and serialize the `messages` array into a
 *   Gemma chat-template prompt (all LiteRT-LM web models are Gemma today).
 *   Mirrors the Android LiteRT-core's `chatTemplate: "llama3" | "plain"`
 *   option — we keep it simple and always use Gemma format since that's
 *   what the web runtime actually ships.
 * - Same lastFatalError contract as WebLLMBackend so the orchestrator's
 *   auto-recovery loop can restart us on blank output / timeout.
 * - Bundled `@litert-lm/core` as an optionalPeerDependency: the runtime
 *   is only pulled into the app's bundle when this backend is selected.
 *
 * ponytail: single-Gemma-template chat serialization. Replace with a
 * tokenizer-aware template map if we ever add non-Gemma models to LiteRT-LM
 * web.
 */

export interface LiteRTLMBackendConfig {
	/**
	 * Path or URL to the `.litertlm` model file. Two supported forms:
	 * - `https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.litertlm`
	 * - Same file hosted alongside your app / on a CDN.
	 * The runtime downloads + compiles it — cold-start typically 20-60s
	 * for the E2B model, cached across page loads.
	 */
	modelUrl: string;
	generationTimeout: number;
	maxBlankChunks: number;
	onProgress?: (info: any) => void;
}

/** Chunk shape produced by @litert-lm/core's sendMessageStreaming iterator. */
interface LiteRTLMStreamChunk {
	text?: string;
	done?: boolean;
	// Some builds also expose token counts / stop reason. We use whatever's
	// present and default the rest defensively.
	stopReason?: string;
}

export class LiteRTLMBackend {
	private engine: any = null;
	private modelUrl: string;
	private generationTimeout: number;
	private maxBlankChunks: number;

	/** Non-null when a fatal state requires unload+reload (matches WebLLMBackend). */
	public lastFatalError: string | null = null;

	constructor(config: LiteRTLMBackendConfig) {
		this.modelUrl = config.modelUrl;
		this.generationTimeout = config.generationTimeout;
		this.maxBlankChunks = config.maxBlankChunks;
	}

	clearFatalError(): void {
		this.lastFatalError = null;
	}

	async initialize(onProgress?: (info: any) => void): Promise<void> {
		if (typeof window === "undefined" || typeof (globalThis as any).navigator === "undefined") {
			throw new Error(
				"[DVAI/LiteRT-LM] Browser-only backend — @litert-lm/core requires WebGPU and a DOM environment.",
			);
		}

		const litertLm = await import("@litert-lm/core");

		// The runtime is worker-based internally (nothing for us to spawn).
		this.engine = await litertLm.Engine.create({
			model: this.modelUrl,
			// The current preview API doesn't document an onProgress hook.
			// We call it once at start so consumer progress UIs still get a signal.
			// ponytail: no per-chunk load progress; wire real hook when Google adds one.
		});
		onProgress?.({ progress: 1, text: "loaded" });
		console.log(`[DVAI/LiteRT-LM] Engine ready (model=${this.modelUrl})`);
	}

	getEngine(): any {
		return this.engine;
	}

	async chatCompletion(requestBody: any): Promise<any> {
		if (!this.engine) throw new Error("LiteRT-LM engine not initialized");

		const prompt = serializeGemmaChat(requestBody?.messages ?? []);
		const conversation = await this.engine.createConversation();
		const text: string = await this.withTimeout(
			conversation.sendMessage(prompt),
			this.generationTimeout,
		);

		if (!text) {
			console.warn("[DVAI/LiteRT-LM] blank content — flagging for full restart");
			this.lastFatalError = "blank_output";
			throw new Error("LiteRT-LM returned blank content. Engine restart required.");
		}

		return openAiResponse(text, requestBody?.model ?? "litertlm");
	}

	createStreamingResponse(requestBody: any): ReadableStream<Uint8Array> {
		const engine = this.engine;
		if (!engine) throw new Error("LiteRT-LM engine not initialized");
		const maxBlankChunks = this.maxBlankChunks;
		const generationTimeout = this.generationTimeout;
		const backend = this;
		const model = requestBody?.model ?? "litertlm";
		const prompt = serializeGemmaChat(requestBody?.messages ?? []);

		return new ReadableStream<Uint8Array>({
			async start(controller) {
				let consecutiveBlanks = 0;
				let timeoutId: ReturnType<typeof setTimeout> | null = null;

				try {
					const conversation = await engine.createConversation();
					const chunks = conversation.sendMessageStreaming(
						prompt,
					) as AsyncIterable<LiteRTLMStreamChunk>;

					const timeoutPromise = new Promise<never>((_, reject) => {
						timeoutId = setTimeout(
							() => reject(new Error(`Generation timed out after ${generationTimeout}ms`)),
							generationTimeout,
						);
					});

					const streamPromise = (async () => {
						for await (const chunk of chunks) {
							const delta = chunk?.text ?? "";
							if (!delta) {
								if (chunk?.done) break;
								consecutiveBlanks++;
								if (consecutiveBlanks >= maxBlankChunks) {
									console.warn(
										`[DVAI/LiteRT-LM] ${maxBlankChunks} blank chunks — flagging restart`,
									);
									backend.lastFatalError = "blank_stream";
									controller.enqueue(sse({
										error: "Stream aborted: too many blank chunks. Engine restart required.",
									}));
									break;
								}
								continue;
							}
							consecutiveBlanks = 0;
							controller.enqueue(sse(openAiChunk(delta, model)));
							if (chunk.done) break;
						}
					})();

					await Promise.race([streamPromise, timeoutPromise]);
				} catch (error: any) {
					console.error("[DVAI/LiteRT-LM] stream error:", error.message);
					if (error.message?.includes("timed out")) backend.lastFatalError = "timeout";
					controller.enqueue(sse({ error: error.message }));
				} finally {
					if (timeoutId) clearTimeout(timeoutId);
					controller.enqueue(new TextEncoder().encode("data: [DONE]\n\n"));
					controller.close();
				}
			},
		});
	}

	async unload(): Promise<void> {
		if (this.engine?.close) {
			try {
				await this.engine.close();
			} catch {
				/* best effort */
			}
		}
		this.engine = null;
	}

	private withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
		return new Promise<T>((resolve, reject) => {
			const timer = setTimeout(
				() => reject(new Error(`Generation timed out after ${ms}ms`)),
				ms,
			);
			promise
				.then((val) => {
					clearTimeout(timer);
					resolve(val);
				})
				.catch((err) => {
					clearTimeout(timer);
					reject(err);
				});
		});
	}
}

// ── helpers (kept in-file — one caller each) ─────────────────────────

/** Gemma chat template. Same shape LiteRT-LM Android core uses. */
export function serializeGemmaChat(
	messages: Array<{ role: string; content: string }>,
): string {
	const parts: string[] = [];
	for (const m of messages) {
		const role = m.role === "assistant" ? "model" : m.role === "system" ? "user" : m.role;
		parts.push(`<start_of_turn>${role}\n${m.content}\n<end_of_turn>`);
	}
	parts.push("<start_of_turn>model\n");
	return parts.join("\n");
}

function openAiResponse(text: string, model: string): any {
	return {
		id: `chatcmpl-litertlm-${Date.now()}`,
		object: "chat.completion",
		created: Math.floor(Date.now() / 1000),
		model,
		choices: [
			{
				index: 0,
				message: { role: "assistant", content: text },
				finish_reason: "stop",
			},
		],
	};
}

function openAiChunk(delta: string, model: string): any {
	return {
		id: `chatcmpl-litertlm-${Date.now()}`,
		object: "chat.completion.chunk",
		created: Math.floor(Date.now() / 1000),
		model,
		choices: [{ index: 0, delta: { content: delta }, finish_reason: null }],
	};
}

function sse(obj: any): Uint8Array {
	return new TextEncoder().encode(`data: ${JSON.stringify(obj)}\n\n`);
}
