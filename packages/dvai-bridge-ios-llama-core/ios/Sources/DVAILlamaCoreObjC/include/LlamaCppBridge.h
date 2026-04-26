#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C++ bridge to llama.cpp. Wraps the C API for use from Swift via the
/// `DVAICapacitorLlamaObjC` module. Owns the `llama_model` and `llama_context`
/// for the lifetime of a load/unload cycle.
@interface LlamaCppBridge : NSObject

@property (nonatomic, readonly, getter=isLoaded) BOOL loaded;
@property (nonatomic, readonly, copy, nullable) NSString *currentModelPath;

- (instancetype)init;

- (BOOL)loadModelAtPath:(NSString *)path
             mmprojPath:(nullable NSString *)mmprojPath
              gpuLayers:(int)gpuLayers
            contextSize:(int)contextSize
                threads:(int)threads
          embeddingMode:(BOOL)embeddingMode
                  error:(NSError **)error;

- (void)unload;

- (NSString *)versionString;

/// Greedy-sample `maxTokens` tokens from the loaded model for the given prompt.
/// `temperature` and `topP` are accepted but currently ignored — this entry point
/// uses a deterministic greedy sampler for Task 30. Future work (Task 36) will
/// honour temperature/top-p via additional sampler-chain stages.
- (nullable NSString *)completePrompt:(NSString *)prompt
                            maxTokens:(int)maxTokens
                          temperature:(float)temperature
                                 topP:(float)topP
                                error:(NSError **)error;

/// Compute an embedding vector for the given text. Requires the model to have
/// been loaded with `embeddingMode:YES`; otherwise the returned values are
/// undefined / not meaningful (the handler layer is responsible for the 400
/// short-circuit before we get here). Returns the per-dimension floats (length
/// == llama_n_embd(model)) wrapped as `NSNumber` doubles.
- (nullable NSArray<NSNumber *> *)embedding:(NSString *)text
                                      error:(NSError **)error;

/// Whether a multimodal projector (mmproj) has been loaded for this bridge.
@property (nonatomic, readonly, getter=isMmprojLoaded) BOOL mmprojLoaded;

/// Load a multimodal projector (mmproj). The main model must already be
/// loaded — the projector is always paired with a text model. Phase 2A Pass 2
/// wires the real `mtmd_init_from_file()` call.
///
/// `useGPU` controls `mtmd_context_params.use_gpu`. Pass `YES` for production
/// (Metal-accelerated CLIP / vision-encoder pass on real iPhone). Pass `NO`
/// in environments where Metal allocation can't accommodate the projector's
/// position-embedding tensor — most commonly the iOS Simulator, where
/// `_xpc_shmem_create_with_prot` aborts on tensors >~ 60 MiB. The bridge
/// uses YES by default. Returns NO on failure (with `error` populated).
- (BOOL)loadMmprojAtPath:(NSString *)mmprojPath
                  useGPU:(BOOL)useGPU
                   error:(NSError **)error;

/// Convenience wrapper that defaults `useGPU:YES`. Most callers want this.
- (BOOL)loadMmprojAtPath:(NSString *)mmprojPath
                   error:(NSError **)error;

/// Unload the multimodal projector. Safe to call when nothing is loaded
/// (idempotent). Frees the underlying mtmd_context.
- (void)unloadMmproj;

/// Apply a chat template via `llama_chat_apply_template`. If `templateOverride`
/// is nil/empty, the model's bundled `tokenizer.chat_template` (via
/// `llama_model_chat_template`) is used. `messages` is an array of
/// `@{ @"role": @"...", @"content": @"..." }` dicts. Returns the rendered
/// prompt string with role markers; multimodal callers should pre-populate
/// `<__media__>` markers in the content fields where image/audio bytes will
/// splice in.
- (nullable NSString *)applyChatTemplate:(nullable NSString *)templateOverride
                                messages:(NSArray<NSDictionary<NSString *, NSString *> *> *)messages
                            addAssistant:(BOOL)addAssistant
                                   error:(NSError **)error;

/// Multimodal completion. `prompt` must contain N `<__media__>` markers
/// matching the count of `media`. Bytes are auto-detected as image or audio
/// via `mtmd_helper_bitmap_init_from_buf` (magic bytes); the caller must
/// supply media in declaration order (i.e. the same order the markers
/// appear in `prompt`). Returns the generated text. Throws on tokenization
/// / eval / decode failures.
- (nullable NSString *)completeMultimodalPrompt:(NSString *)prompt
                                          media:(NSArray<NSData *> *)mediaInOrder
                                      maxTokens:(int)maxTokens
                                    temperature:(float)temperature
                                           topP:(float)topP
                                          error:(NSError **)error;

/// Returns YES if the loaded model declares an audio encoder (via
/// `mtmd_support_audio()`). Always NO when no mmproj is loaded.
- (BOOL)hasAudioEncoder;

@end

NS_ASSUME_NONNULL_END
