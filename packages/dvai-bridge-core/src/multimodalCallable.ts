/**
 * Shared helpers for the declarative multimodal loader path (used by both
 * the main-thread `TransformersBackend` and the worker-side init handler).
 *
 * The idea: a host app tells dvai-bridge "load model `X` via class `Y` with
 * processor `Z`, and null fields `F1, F2` after load". dvai-bridge does it
 * — no model-family knowledge baked into the library. If tomorrow a host
 * wants to run a Qwen-VL or an Idefics model, it's the same config surface;
 * if transformers.js exports the class, this path loads it.
 *
 * Limitation: the generic callable assumes the common `processor(prompt,
 * images, audio, options)` call signature. Most HuggingFace multimodal
 * processors follow this shape; ones that don't (e.g. processors taking
 * kwargs like `{ images, audios, videos }`) should fall back to the
 * main-thread `createPipeline` factory, which gives the host full control.
 * That path is still supported.
 */

/**
 * Extract the media content parts (audio / images) from the last user
 * message in a chat-messages array. Returns `null` for a modality that
 * isn't present, so the processor call can pass-through.
 *
 * Content shape assumed per the OpenAI-compatible convention:
 *   { role, content: string | Array<{ type: 'text'|'audio'|'image', ... }> }
 * with dvai-bridge's extension: audio parts carry `{ type: 'audio', data: Float32Array }`.
 */
export function extractMediaParts(messages: any[]): {
	audio: Float32Array | null;
	images: unknown[] | null;
} {
	const last = messages[messages.length - 1];
	if (!last || !Array.isArray(last.content)) {
		return { audio: null, images: null };
	}
	let audio: Float32Array | null = null;
	const images: unknown[] = [];
	for (const part of last.content) {
		if (!part) continue;
		if (part.type === "audio" && part.data) {
			audio = part.data as Float32Array;
		} else if (part.type === "image" && (part.image || part.data || part.url)) {
			// Push whichever field the host used; downstream processor accepts
			// various shapes (URL, RawImage, tensor). dvai-bridge stays
			// opinion-free here.
			images.push(part.image ?? part.data ?? part.url);
		}
	}
	return { audio, images: images.length > 0 ? images : null };
}

export interface MultimodalCallableOptions {
	/** Default max_new_tokens if caller doesn't specify. */
	defaultMaxNewTokens?: number;
}

/**
 * Build a pipeline-shaped callable `(messages, options) => [{ generated_text }]`
 * that wraps a `(model, processor)` pair loaded by the declarative path.
 * Matches the contract of transformers.js's `pipeline()` output so the rest
 * of the backend code (chat completion, streaming, runPipeline) can treat
 * it interchangeably.
 *
 * The returned function also carries `.tokenizer` (for TextStreamer) and
 * `.dispose()` (for VRAM release during unload) as instance properties.
 */
export function buildMultimodalCallable(
	model: any,
	processor: any,
	opts: MultimodalCallableOptions = {},
): any {
	const defaultMaxNewTokens = opts.defaultMaxNewTokens ?? 1024;

	const callable: any = async (messages: any, options: any) => {
		const prompt = processor.apply_chat_template(messages, {
			enable_thinking: false,
			add_generation_prompt: true,
		});
		const { audio, images } = extractMediaParts(messages);
		const inputs = await processor(prompt, images, audio, {
			add_special_tokens: false,
		});
		const genArgs: Record<string, unknown> = {
			...inputs,
			max_new_tokens: options?.max_new_tokens ?? defaultMaxNewTokens,
			temperature: options?.temperature ?? 0,
			do_sample: options?.do_sample ?? false,
			top_p: options?.top_p ?? 1,
		};
		if (options?.streamer) genArgs.streamer = options.streamer;
		const outputs = await model.generate(genArgs);
		const promptLen = inputs.input_ids.dims.at(-1);
		const generated = outputs.slice(null, [promptLen, null]);
		const decoded = processor.batch_decode(generated, {
			skip_special_tokens: true,
		});
		return [{ generated_text: decoded[0] ?? "" }];
	};

	// TextStreamer uses this to tokenize partial outputs during streaming.
	callable.tokenizer = processor.tokenizer;

	// dvai-bridge calls this on unload to release VRAM held by the ONNX
	// session(s) behind the model. AutoProcessor has no dispose() in current
	// transformers.js, so we only drop the model's sessions.
	callable.dispose = async () => {
		try {
			await model.dispose?.();
		} catch {
			/* ignore */
		}
	};

	return callable;
}

/**
 * Null out named submodules on a loaded model to reclaim memory. Host apps
 * pass a list of field names (e.g., `['vision_encoder']`) based on which
 * modalities they don't use. dvai-bridge treats this as purely declarative —
 * it walks the list and nulls each field if present.
 */
export function disableModelEncoders(model: any, names: string[] | undefined): void {
	if (!names || names.length === 0) return;
	for (const name of names) {
		try {
			if (model && (model as any)[name]) {
				(model as any)[name] = null;
			}
		} catch {
			/* ignore — name didn't exist or was non-writable */
		}
	}
}
