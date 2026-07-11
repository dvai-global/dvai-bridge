import { describe, it, expect } from 'vitest';

describe('LiteRTLMBackend', () => {
  it('accepts config + starts uninitialized', async () => {
    const { LiteRTLMBackend } = await import('../LiteRTLMBackend');
    const backend = new LiteRTLMBackend({
      modelUrl: 'https://example/gemma.litertlm',
      generationTimeout: 5000,
      maxBlankChunks: 20,
    });
    expect(backend.getEngine()).toBe(null);
    expect(backend.lastFatalError).toBe(null);
  });

  it('serializes messages using Gemma chat template', async () => {
    const { serializeGemmaChat } = await import('../LiteRTLMBackend');
    const prompt = serializeGemmaChat([
      { role: 'system', content: 'You are helpful.' },
      { role: 'user', content: 'hi' },
      { role: 'assistant', content: 'hello' },
      { role: 'user', content: 'how are you?' },
    ]);
    // System is collapsed into "user" turn (LiteRT-LM web has no system role).
    // Assistant maps to "model". Ends with a fresh <start_of_turn>model to trigger generation.
    expect(prompt).toContain('<start_of_turn>user\nYou are helpful.');
    expect(prompt).toContain('<start_of_turn>user\nhi');
    expect(prompt).toContain('<start_of_turn>model\nhello');
    expect(prompt).toContain('<start_of_turn>user\nhow are you?');
    expect(prompt.trimEnd().endsWith('<start_of_turn>model')).toBe(true);
  });

  it('clearFatalError resets the flag', async () => {
    const { LiteRTLMBackend } = await import('../LiteRTLMBackend');
    const backend = new LiteRTLMBackend({
      modelUrl: 'x',
      generationTimeout: 100,
      maxBlankChunks: 1,
    });
    // Directly poke — public API surface matches WebLLMBackend.
    (backend as unknown as { lastFatalError: string }).lastFatalError = 'blank_output';
    backend.clearFatalError();
    expect(backend.lastFatalError).toBe(null);
  });
});
