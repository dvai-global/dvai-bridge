#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C++ bridge to llama.cpp. Real implementation lands in Task 30;
/// this stub exposes the interface so Swift code (LlamaHandlers, PluginState)
/// can compile against it.
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

@end

NS_ASSUME_NONNULL_END
