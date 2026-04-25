// Loader for shared fixtures at fixtures/transport-fixtures.json.
// All three platforms (TS, Swift, Kotlin) read the same JSON.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { BackendInterface, HandlerContext } from "../handlers/context";

const FIXTURES_ROOT = resolve(__dirname, "../../../../fixtures");

const raw = JSON.parse(
  readFileSync(resolve(FIXTURES_ROOT, "transport-fixtures.json"), "utf8"),
);

// Substitute the audio data placeholder with real base64-encoded PCM16
const pcm16Bytes = readFileSync(resolve(FIXTURES_ROOT, "audio/pcm16-1s-16khz-mono.bin"));
const pcm16Base64 = pcm16Bytes.toString("base64");
raw.CHAT_REQUEST_AUDIO_PCM16.messages[0].content[0].input_audio.data = pcm16Base64;

export const CHAT_REQUEST = raw.CHAT_REQUEST_TEXT;
export const CHAT_REQUEST_IMAGE = raw.CHAT_REQUEST_IMAGE;
export const CHAT_REQUEST_AUDIO_PCM16 = raw.CHAT_REQUEST_AUDIO_PCM16;
export const COMPLETION_REQUEST = raw.COMPLETION_REQUEST;
export const EMBEDDING_REQUEST = raw.EMBEDDING_REQUEST;
export const CANNED_CHAT_COMPLETION = raw.CANNED_CHAT_COMPLETION;
export const CANNED_EMBEDDING = raw.CANNED_EMBEDDING;

export function makeStreamBackend(): BackendInterface {
  return {
    chatCompletion: async () => CANNED_CHAT_COMPLETION,
    createStreamingResponse: () => {
      const encoder = new TextEncoder();
      return new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(
            encoder.encode(
              `data: ${JSON.stringify({ id: "chatcmpl-fixed", choices: [{ delta: { content: "canned" }, index: 0 }] })}\n\n`,
            ),
          );
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        },
      });
    },
    embedding: async (inputs) => {
      const arr = Array.isArray(inputs) ? inputs : [inputs];
      return arr.map((_, i) => [i * 0.1, i * 0.2, i * 0.3]);
    },
  };
}

export function makeCtx(
  backend: BackendInterface = makeStreamBackend(),
  overrides: Partial<HandlerContext> = {},
): HandlerContext {
  return {
    backend,
    resolvedBackend: "transformers",
    modelId: "test-model",
    ...overrides,
  };
}
