import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const FIXTURES_PATH = resolve(__dirname, "../../../../fixtures/transport-fixtures.json");

describe("transport-fixtures.json shape", () => {
  const raw = JSON.parse(readFileSync(FIXTURES_PATH, "utf8"));

  it("has all required top-level keys", () => {
    expect(Object.keys(raw)).toEqual(
      expect.arrayContaining([
        "CHAT_REQUEST_TEXT",
        "CHAT_REQUEST_IMAGE",
        "CHAT_REQUEST_AUDIO_PCM16",
        "COMPLETION_REQUEST",
        "EMBEDDING_REQUEST",
        "CANNED_CHAT_COMPLETION",
        "CANNED_EMBEDDING",
      ]),
    );
  });

  it("CHAT_REQUEST_IMAGE has data URL image content", () => {
    const part = raw.CHAT_REQUEST_IMAGE.messages[0].content.find(
      (p: any) => p.type === "image_url",
    );
    expect(part.image_url.url).toMatch(/^data:image\/png;base64,/);
  });

  it("CHAT_REQUEST_AUDIO_PCM16 has audio content with placeholder data", () => {
    const part = raw.CHAT_REQUEST_AUDIO_PCM16.messages[0].content.find(
      (p: any) => p.type === "input_audio",
    );
    expect(part.input_audio.format).toBe("pcm16");
    // The literal placeholder is replaced by the loader at runtime
    expect(typeof part.input_audio.data).toBe("string");
  });

  it("CANNED_CHAT_COMPLETION has stable id 'chatcmpl-fixed'", () => {
    expect(raw.CANNED_CHAT_COMPLETION.id).toBe("chatcmpl-fixed");
  });

  it("CANNED_CHAT_COMPLETION has the canonical chat.completion shape", () => {
    expect(raw.CANNED_CHAT_COMPLETION.object).toBe("chat.completion");
    expect(Array.isArray(raw.CANNED_CHAT_COMPLETION.choices)).toBe(true);
    expect(raw.CANNED_CHAT_COMPLETION.choices.length).toBe(1);
    expect(raw.CANNED_CHAT_COMPLETION.usage).toMatchObject({
      prompt_tokens: expect.any(Number),
      completion_tokens: expect.any(Number),
      total_tokens: expect.any(Number),
    });
  });
});
