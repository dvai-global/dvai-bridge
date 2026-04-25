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

@end

NS_ASSUME_NONNULL_END
