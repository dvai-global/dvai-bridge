import { describe, it, expect, vi } from 'vitest';

describe('TransformersBackend Multi-modal Support', () => {
  it('should accept various pipeline tasks via config', async () => {
    const { TransformersBackend } = await import('../TransformersBackend');

    const tasks = [
      'text-generation',
      'text-to-image',
      'automatic-speech-recognition',
      'image-to-text',
      'text-to-speech',
      'feature-extraction',
      'summarization',
      'translation',
    ];

    for (const task of tasks) {
      const backend = new TransformersBackend({
        modelId: 'test-model',
        device: 'cpu',
        generationTimeout: 5000,
        pipelineTask: task,
      });
      expect(backend.getPipelineTask()).toBe(task);
    }
  });

  it('should classify text tasks correctly', async () => {
    const { TransformersBackend } = await import('../TransformersBackend');

    const textTasks = ['text-generation', 'text2text-generation', 'summarization', 'translation'];
    const nonTextTasks = ['text-to-image', 'automatic-speech-recognition', 'image-to-text', 'text-to-speech'];

    for (const task of textTasks) {
      const backend = new TransformersBackend({
        modelId: 'test-model',
        device: 'cpu',
        generationTimeout: 5000,
        pipelineTask: task,
      });
      expect(backend.isTextTask()).toBe(true);
    }

    for (const task of nonTextTasks) {
      const backend = new TransformersBackend({
        modelId: 'test-model',
        device: 'cpu',
        generationTimeout: 5000,
        pipelineTask: task,
      });
      expect(backend.isTextTask()).toBe(false);
    }
  });

  it('should throw on chatCompletion for non-text tasks', async () => {
    const { TransformersBackend } = await import('../TransformersBackend');

    const backend = new TransformersBackend({
      modelId: 'test-model',
      device: 'cpu',
      generationTimeout: 5000,
      pipelineTask: 'text-to-image',
    });

    // Mock pipeline as initialized
    (backend as any).pipeline = vi.fn();

    await expect(
      backend.chatCompletion({ messages: [{ role: 'user', content: 'Hello' }] })
    ).rejects.toThrow('only available for text-generation tasks');
  });

  it('should allow runPipeline for any task', async () => {
    const { TransformersBackend } = await import('../TransformersBackend');

    const backend = new TransformersBackend({
      modelId: 'test-model',
      device: 'cpu',
      generationTimeout: 5000,
      pipelineTask: 'text-to-image',
    });

    const mockResult = { images: ['blob:123'] };
    (backend as any).pipeline = vi.fn().mockResolvedValue(mockResult);

    const result = await backend.runPipeline('A cute cat', { num_images: 1 });
    expect(result).toEqual(mockResult);
    expect((backend as any).pipeline).toHaveBeenCalledWith('A cute cat', { num_images: 1 });
  });
});

describe('WebGPU Detection', () => {
  it('should return false when navigator is undefined', async () => {
    const { detectWebGPU } = await import('../TransformersBackend');
    // In Node.js test env, navigator is undefined
    const result = await detectWebGPU();
    expect(result).toBe(false);
  });
});

describe('TransformersBackend OpenAI Wrapper', () => {
  it('should format non-streaming response as OpenAI API', async () => {
    const { TransformersBackend } = await import('../TransformersBackend');

    const backend = new TransformersBackend({
      modelId: 'test-model',
      device: 'cpu',
      generationTimeout: 5000,
      pipelineTask: 'text-generation',
    });

    // Mock pipeline returning text-generation result
    (backend as any).pipeline = vi.fn().mockResolvedValue([
      { generated_text: 'Hello, I am an AI assistant.' },
    ]);

    const result = await backend.chatCompletion({
      messages: [{ role: 'user', content: 'Hi' }],
    });

    expect(result.object).toBe('chat.completion');
    expect(result.choices).toHaveLength(1);
    expect(result.choices[0].message.role).toBe('assistant');
    expect(result.choices[0].message.content).toBe('Hello, I am an AI assistant.');
    expect(result.choices[0].finish_reason).toBe('stop');
    expect(result.model).toBe('test-model');
  });

  it('should handle array-of-messages generated_text format', async () => {
    const { TransformersBackend } = await import('../TransformersBackend');

    const backend = new TransformersBackend({
      modelId: 'test-model',
      device: 'cpu',
      generationTimeout: 5000,
      pipelineTask: 'text-generation',
    });

    // Some models return generated_text as array of message objects
    (backend as any).pipeline = vi.fn().mockResolvedValue([
      {
        generated_text: [
          { role: 'user', content: 'Hi' },
          { role: 'assistant', content: 'Hello there!' },
        ],
      },
    ]);

    const result = await backend.chatCompletion({
      messages: [{ role: 'user', content: 'Hi' }],
    });

    expect(result.choices[0].message.content).toBe('Hello there!');
  });
});
