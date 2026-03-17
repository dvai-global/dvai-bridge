import { describe, it, expect, vi, beforeEach } from 'vitest';

/**
 * Tests for the blank-chunk detection and timeout logic in WebLLMBackend.
 * We mock the web-llm module to simulate various stream behaviors.
 */

// Mock the engine behavior
function createMockEngine(chunks: any[]) {
  return {
    chat: {
      completions: {
        create: vi.fn().mockImplementation(async (options: any) => {
          if (options.stream) {
            return (async function* () {
              for (const chunk of chunks) {
                yield chunk;
              }
            })();
          }
          // Non-streaming
          return chunks[0];
        }),
      },
    },
    interruptGenerate: vi.fn(),
    resetChat: vi.fn(),
    unload: vi.fn(),
    reload: vi.fn(),
  };
}

describe('WebLLM Blank Chunk Detection', () => {
  it('should abort stream after maxBlankChunks consecutive blanks', async () => {
    // Generate 25 blank chunks (exceeds default of 20)
    const blankChunks = Array.from({ length: 25 }, (_, i) => ({
      choices: [{ delta: { content: '' }, finish_reason: null }],
    }));

    const mockEngine = createMockEngine(blankChunks);

    // Dynamically import and test
    const { WebLLMBackend } = await import('../WebLLMBackend');
    const backend = new WebLLMBackend({
      modelId: 'test-model',
      generationTimeout: 5000,
      maxBlankChunks: 5, // Lower threshold for test speed
    });

    // Inject mock engine
    (backend as any).engine = mockEngine;

    const stream = backend.createStreamingResponse({ stream: true, messages: [] });
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    const chunks: string[] = [];

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(decoder.decode(value));
    }

    const allOutput = chunks.join('');
    expect(allOutput).toContain('Stream aborted: too many blank chunks');
    expect(allOutput).toContain('[DONE]');
    expect(mockEngine.interruptGenerate).toHaveBeenCalled();
    expect(mockEngine.resetChat).toHaveBeenCalled();
  });

  it('should complete normally when content chunks are received', async () => {
    const contentChunks = [
      { choices: [{ delta: { content: 'Hello' }, finish_reason: null }] },
      { choices: [{ delta: { content: ' world' }, finish_reason: null }] },
      { choices: [{ delta: { content: '!' }, finish_reason: 'stop' }] },
    ];

    const mockEngine = createMockEngine(contentChunks);

    const { WebLLMBackend } = await import('../WebLLMBackend');
    const backend = new WebLLMBackend({
      modelId: 'test-model',
      generationTimeout: 5000,
      maxBlankChunks: 20,
    });
    (backend as any).engine = mockEngine;

    const stream = backend.createStreamingResponse({ stream: true, messages: [] });
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    const chunks: string[] = [];

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(decoder.decode(value));
    }

    const allOutput = chunks.join('');
    expect(allOutput).toContain('Hello');
    expect(allOutput).toContain(' world');
    expect(allOutput).toContain('[DONE]');
    expect(allOutput).not.toContain('Stream aborted');
  });

  it('should reset blank counter when a content chunk is received', async () => {
    // 3 blank, then content, then 3 blank, then content, then stop
    const mixedChunks = [
      { choices: [{ delta: { content: '' }, finish_reason: null }] },
      { choices: [{ delta: { content: '' }, finish_reason: null }] },
      { choices: [{ delta: { content: '' }, finish_reason: null }] },
      { choices: [{ delta: { content: 'Hi' }, finish_reason: null }] },
      { choices: [{ delta: { content: '' }, finish_reason: null }] },
      { choices: [{ delta: { content: '' }, finish_reason: null }] },
      { choices: [{ delta: { content: '' }, finish_reason: null }] },
      { choices: [{ delta: { content: ' there' }, finish_reason: 'stop' }] },
    ];

    const mockEngine = createMockEngine(mixedChunks);

    const { WebLLMBackend } = await import('../WebLLMBackend');
    const backend = new WebLLMBackend({
      modelId: 'test-model',
      generationTimeout: 5000,
      maxBlankChunks: 5, // threshold is 5, so 3 blanks should NOT trigger abort
    });
    (backend as any).engine = mockEngine;

    const stream = backend.createStreamingResponse({ stream: true, messages: [] });
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    const chunks: string[] = [];

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(decoder.decode(value));
    }

    const allOutput = chunks.join('');
    expect(allOutput).toContain('Hi');
    expect(allOutput).toContain(' there');
    expect(allOutput).not.toContain('Stream aborted');
  });

  it('should throw on blank non-streaming response and reset engine', async () => {
    const mockEngine = createMockEngine([
      { choices: [{ message: { content: '' } }] },
    ]);

    const { WebLLMBackend } = await import('../WebLLMBackend');
    const backend = new WebLLMBackend({
      modelId: 'test-model',
      generationTimeout: 5000,
      maxBlankChunks: 20,
    });
    (backend as any).engine = mockEngine;

    await expect(backend.chatCompletion({ messages: [] })).rejects.toThrow('blank content');
    expect(mockEngine.resetChat).toHaveBeenCalled();
  });
});

describe('WebLLM Generation Timeout', () => {
  it('should timeout on a hanging stream', async () => {
    // Create a stream that never emits finish_reason
    const hangingChunks: any[] = [];
    for (let i = 0; i < 1000; i++) {
      hangingChunks.push({
        choices: [{ delta: { content: `token${i}` }, finish_reason: null }],
      });
    }

    const mockEngine = {
      chat: {
        completions: {
          create: vi.fn().mockImplementation(async (options: any) => {
            if (options.stream) {
              return (async function* () {
                for (const chunk of hangingChunks) {
                  yield chunk;
                  // Simulate slow generation
                  await new Promise((r) => setTimeout(r, 50));
                }
              })();
            }
          }),
        },
      },
      interruptGenerate: vi.fn(),
      resetChat: vi.fn(),
      unload: vi.fn(),
    };

    const { WebLLMBackend } = await import('../WebLLMBackend');
    const backend = new WebLLMBackend({
      modelId: 'test-model',
      generationTimeout: 200, // Very short timeout for test
      maxBlankChunks: 20,
    });
    (backend as any).engine = mockEngine;

    const stream = backend.createStreamingResponse({ stream: true, messages: [] });
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    const chunks: string[] = [];

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(decoder.decode(value));
    }

    const allOutput = chunks.join('');
    expect(allOutput).toContain('timed out');
  });
});
