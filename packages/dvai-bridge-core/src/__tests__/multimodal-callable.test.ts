import { describe, it, expect, vi } from 'vitest';
import {
  extractMediaParts,
  buildMultimodalCallable,
  disableModelEncoders,
} from '../multimodalCallable';

describe('extractMediaParts', () => {
  it('returns nulls when last message has string content', () => {
    const res = extractMediaParts([
      { role: 'user', content: 'just text' },
    ]);
    expect(res).toEqual({ audio: null, images: null });
  });

  it('returns nulls when messages array is empty', () => {
    expect(extractMediaParts([])).toEqual({ audio: null, images: null });
  });

  it('extracts Float32Array audio from the last user message', () => {
    const audio = new Float32Array([0.1, 0.2, 0.3]);
    const res = extractMediaParts([
      { role: 'system', content: 'You are a helpful assistant' },
      {
        role: 'user',
        content: [
          { type: 'text', text: 'transcribe this' },
          { type: 'audio', data: audio },
        ],
      },
    ]);
    expect(res.audio).toBe(audio);
    expect(res.images).toBeNull();
  });

  it('extracts images from the last user message', () => {
    const res = extractMediaParts([
      {
        role: 'user',
        content: [
          { type: 'text', text: 'describe' },
          { type: 'image', image: 'blob:abc' },
          { type: 'image', url: 'https://example/cat.png' },
        ],
      },
    ]);
    expect(res.images).toEqual(['blob:abc', 'https://example/cat.png']);
    expect(res.audio).toBeNull();
  });

  it('only inspects the LAST message (prior audio/image ignored)', () => {
    const audio = new Float32Array([0.5]);
    const res = extractMediaParts([
      { role: 'user', content: [{ type: 'audio', data: audio }] },
      { role: 'assistant', content: 'ok' },
      { role: 'user', content: 'plain text' },
    ]);
    expect(res.audio).toBeNull();
    expect(res.images).toBeNull();
  });
});

describe('disableModelEncoders', () => {
  it('nulls named submodules', () => {
    const model = {
      vision_encoder: { layers: 12 },
      audio_encoder: { layers: 8 },
      decoder: { layers: 24 },
    };
    disableModelEncoders(model, ['vision_encoder']);
    expect(model.vision_encoder).toBeNull();
    expect(model.audio_encoder).not.toBeNull();
    expect(model.decoder).not.toBeNull();
  });

  it('ignores unknown names silently', () => {
    const model: any = { decoder: {} };
    expect(() => disableModelEncoders(model, ['does_not_exist'])).not.toThrow();
    expect(model.decoder).not.toBeNull();
  });

  it('no-ops on empty / undefined list', () => {
    const model: any = { vision_encoder: {} };
    disableModelEncoders(model, undefined);
    disableModelEncoders(model, []);
    expect(model.vision_encoder).not.toBeNull();
  });
});

describe('buildMultimodalCallable', () => {
  function makeProcessor() {
    return {
      apply_chat_template: vi.fn().mockReturnValue('<rendered-prompt>'),
      batch_decode: vi.fn().mockReturnValue(['decoded text']),
      tokenizer: { name: 'mock-tokenizer' },
      // Callable itself (processor(prompt, images, audio, opts)):
      ...Object.assign(
        vi.fn().mockImplementation(async () => ({
          input_ids: { dims: [1, 4] },
        })),
        {},
      ),
    };
  }

  function makeCallableProcessor() {
    const fn = vi.fn().mockResolvedValue({ input_ids: { dims: [1, 4] } });
    const proc: any = fn;
    proc.apply_chat_template = vi.fn().mockReturnValue('<rendered-prompt>');
    proc.batch_decode = vi.fn().mockReturnValue(['decoded text']);
    proc.tokenizer = { name: 'mock-tokenizer' };
    return proc;
  }

  function makeModel() {
    return {
      generate: vi.fn().mockResolvedValue({
        slice: vi.fn().mockImplementation(() => 'generated-tensor'),
      }),
      dispose: vi.fn().mockResolvedValue(undefined),
    };
  }

  it('returns [{ generated_text }] matching pipeline shape', async () => {
    const processor = makeCallableProcessor();
    const model = makeModel();
    const callable = buildMultimodalCallable(model, processor);

    const result = await callable(
      [{ role: 'user', content: 'hi' }],
      { max_new_tokens: 128 },
    );
    expect(result).toEqual([{ generated_text: 'decoded text' }]);
  });

  it('exposes processor.tokenizer for TextStreamer', () => {
    const processor = makeCallableProcessor();
    const model = makeModel();
    const callable = buildMultimodalCallable(model, processor);
    expect(callable.tokenizer).toEqual({ name: 'mock-tokenizer' });
  });

  it('dispose() forwards to model.dispose', async () => {
    const processor = makeCallableProcessor();
    const model = makeModel();
    const callable = buildMultimodalCallable(model, processor);
    await callable.dispose();
    expect(model.dispose).toHaveBeenCalled();
  });

  it('passes Float32Array audio to processor unchanged', async () => {
    const processor = makeCallableProcessor();
    const model = makeModel();
    const callable = buildMultimodalCallable(model, processor);
    const audio = new Float32Array([0.1, 0.2]);
    await callable(
      [{ role: 'user', content: [{ type: 'audio', data: audio }] }],
      { max_new_tokens: 64 },
    );
    // processor called as processor(prompt, images, audio, options)
    expect(processor).toHaveBeenCalledWith(
      '<rendered-prompt>',
      null,
      audio,
      expect.any(Object),
    );
  });

  it('forwards streamer option to model.generate', async () => {
    const processor = makeCallableProcessor();
    const model = makeModel();
    const callable = buildMultimodalCallable(model, processor);
    const streamer = { __tag: 'streamer' };
    await callable([{ role: 'user', content: 'hi' }], { streamer });
    const generateArgs = model.generate.mock.calls[0][0];
    expect(generateArgs.streamer).toBe(streamer);
  });

  it('uses default max_new_tokens when caller omits it', async () => {
    const processor = makeCallableProcessor();
    const model = makeModel();
    const callable = buildMultimodalCallable(model, processor, {
      defaultMaxNewTokens: 777,
    });
    await callable([{ role: 'user', content: 'hi' }]);
    const generateArgs = model.generate.mock.calls[0][0];
    expect(generateArgs.max_new_tokens).toBe(777);
  });
});

describe('TransformersBackend declarative config', () => {
  it('stores modelClass / processorClass / disableEncoders from config', async () => {
    const { TransformersBackend } = await import('../TransformersBackend');
    const backend = new TransformersBackend({
      modelId: 'org/gemma-4-E2B-it-ONNX',
      device: 'webgpu',
      generationTimeout: 5000,
      pipelineTask: 'image-text-to-text',
      modelClass: 'Gemma4ForConditionalGeneration',
      processorClass: 'AutoProcessor',
      disableEncoders: ['vision_encoder'],
    });
    // Fields are private but observable via the worker init params path;
    // at minimum we verify the constructor doesn't reject the config shape.
    expect(backend).toBeTruthy();
    expect((backend as any).modelClass).toBe('Gemma4ForConditionalGeneration');
    expect((backend as any).processorClass).toBe('AutoProcessor');
    expect((backend as any).disableEncoders).toEqual(['vision_encoder']);
  });

  it('defaults modelClass / processorClass / disableEncoders to undefined', async () => {
    const { TransformersBackend } = await import('../TransformersBackend');
    const backend = new TransformersBackend({
      modelId: 'bert-base',
      device: 'cpu',
      generationTimeout: 5000,
      pipelineTask: 'feature-extraction',
    });
    expect((backend as any).modelClass).toBeUndefined();
    expect((backend as any).processorClass).toBeUndefined();
    expect((backend as any).disableEncoders).toBeUndefined();
  });
});
