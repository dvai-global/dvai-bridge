#import "LlamaCppBridge.h"
// llama.cpp headers will be #imported when the real implementation lands in Task 30:
// #import "llama.h"

@implementation LlamaCppBridge {
    BOOL _loaded;
    NSString *_currentModelPath;
}

- (instancetype)init {
    if ((self = [super init])) {
        _loaded = NO;
        _currentModelPath = nil;
    }
    return self;
}

- (BOOL)isLoaded {
    return _loaded;
}

- (NSString *)currentModelPath {
    return _currentModelPath;
}

- (BOOL)loadModelAtPath:(NSString *)path
             mmprojPath:(NSString *)mmprojPath
              gpuLayers:(int)gpuLayers
            contextSize:(int)contextSize
                threads:(int)threads
          embeddingMode:(BOOL)embeddingMode
                  error:(NSError **)error {
    if (path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"empty model path"}];
        }
        return NO;
    }
    // Stub: just record the path. Task 30 replaces this with real llama.cpp calls.
    _currentModelPath = [path copy];
    _loaded = YES;
    return YES;
}

- (void)unload {
    _loaded = NO;
    _currentModelPath = nil;
}

- (NSString *)versionString {
    return @"llama.cpp-stub-0.1";
}

@end
