#import "LlamaCppBridge.h"
#import "llama.h"
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <string.h>

@implementation LlamaCppBridge {
    struct llama_model *_model;
    struct llama_context *_ctx;
    NSString *_currentModelPath;
    BOOL _embeddingMode;
}

- (instancetype)init {
    if ((self = [super init])) {
        _model = NULL;
        _ctx = NULL;
        _currentModelPath = nil;
        _embeddingMode = NO;
    }
    return self;
}

- (void)dealloc {
    [self unload];
}

- (BOOL)isLoaded {
    return _model != NULL && _ctx != NULL;
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

    [self unload];

    llama_backend_init();

    struct llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = gpuLayers;
    // llama.cpp b8933: llama_load_model_from_file -> llama_model_load_from_file.
    _model = llama_model_load_from_file([path UTF8String], mp);
    if (_model == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"llama_model_load_from_file failed"}];
        }
        return NO;
    }

    struct llama_context_params cp = llama_context_default_params();
    cp.n_ctx = (uint32_t)contextSize;
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    cp.embeddings = embeddingMode ? true : false;

    // llama.cpp b8933: llama_new_context_with_model -> llama_init_from_model.
    _ctx = llama_init_from_model(_model, cp);
    if (_ctx == NULL) {
        llama_model_free(_model);
        _model = NULL;
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"llama_init_from_model failed"}];
        }
        return NO;
    }

    // mmproj path is just recorded for now. The multimodal projector is loaded
    // on-demand by the multimodal eval path (Task 35); the path lives on the
    // PluginState so handlers can pick it up.
    (void)mmprojPath;

    _currentModelPath = [path copy];
    _embeddingMode = embeddingMode;
    return YES;
}

- (void)unload {
    if (_ctx != NULL) {
        llama_free(_ctx);
        _ctx = NULL;
    }
    if (_model != NULL) {
        // llama.cpp b8933: llama_free_model -> llama_model_free.
        llama_model_free(_model);
        _model = NULL;
    }
    _currentModelPath = nil;
    _embeddingMode = NO;
}

- (NSString *)versionString {
    const char *info = llama_print_system_info();
    return [NSString stringWithFormat:@"llama.cpp %s", info ? info : ""];
}

- (nullable NSString *)completePrompt:(NSString *)prompt
                            maxTokens:(int)maxTokens
                          temperature:(float)temperature
                                 topP:(float)topP
                                error:(NSError **)error {
    (void)temperature;
    (void)topP;

    if (!self.isLoaded) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:10
                                     userInfo:@{NSLocalizedDescriptionKey: @"Model not loaded"}];
        }
        return nil;
    }

    const char *cprompt = prompt ? [prompt UTF8String] : "";
    const int promptLen = (int)strlen(cprompt);

    // llama.cpp b8933: tokenize / token_to_piece / token_eos now take a vocab,
    // not a model. Fetch it once and reuse.
    const struct llama_vocab *vocab = llama_model_get_vocab(_model);

    // Probe: a negative return is the (negated) required token count.
    int probe = llama_tokenize(vocab, cprompt, promptLen,
                               NULL, 0, /*add_special=*/true, /*parse_special=*/false);
    int needed = probe < 0 ? -probe : probe;
    if (needed <= 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:11
                                     userInfo:@{NSLocalizedDescriptionKey: @"Tokenization produced no tokens"}];
        }
        return nil;
    }

    llama_token *tokens = (llama_token *)calloc((size_t)needed, sizeof(llama_token));
    if (tokens == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:11
                                     userInfo:@{NSLocalizedDescriptionKey: @"calloc failed"}];
        }
        return nil;
    }

    int actual = llama_tokenize(vocab, cprompt, promptLen,
                                tokens, needed, /*add_special=*/true, /*parse_special=*/false);
    if (actual <= 0) {
        free(tokens);
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:11
                                     userInfo:@{NSLocalizedDescriptionKey: @"Tokenization failed"}];
        }
        return nil;
    }

    // llama.cpp b8933: llama_batch_get_one is now (tokens, n_tokens) only -- the
    // pos_0 / seq_id args were removed. Position is tracked automatically by
    // llama_decode via the context's KV cache state.
    struct llama_batch batch = llama_batch_get_one(tokens, actual);
    if (llama_decode(_ctx, batch) != 0) {
        free(tokens);
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:12
                                     userInfo:@{NSLocalizedDescriptionKey: @"Decode failed"}];
        }
        return nil;
    }
    free(tokens);

    // Build a simple greedy sampler chain. Temperature and top-p will be wired
    // in Task 36 by extending this chain.
    struct llama_sampler_chain_params sp = llama_sampler_chain_default_params();
    struct llama_sampler *chain = llama_sampler_chain_init(sp);
    llama_sampler_chain_add(chain, llama_sampler_init_greedy());

    NSMutableString *result = [NSMutableString string];
    // llama.cpp b8933: llama_token_eos -> llama_vocab_eos (vocab arg).
    const llama_token eos = llama_vocab_eos(vocab);

    for (int i = 0; i < maxTokens; i++) {
        llama_token tokenId = llama_sampler_sample(chain, _ctx, -1);
        llama_sampler_accept(chain, tokenId);

        if (tokenId == eos) break;

        char buf[256] = {0};
        // llama.cpp b8933: llama_token_to_piece first arg is vocab, not model.
        int wrote = llama_token_to_piece(vocab, tokenId, buf, (int)sizeof(buf),
                                         /*lstrip=*/0, /*special=*/false);
        if (wrote > 0) {
            NSString *piece = [[NSString alloc] initWithBytes:buf
                                                       length:(NSUInteger)wrote
                                                     encoding:NSUTF8StringEncoding];
            if (piece != nil) {
                [result appendString:piece];
            }
        }

        struct llama_batch nb = llama_batch_get_one(&tokenId, 1);
        if (llama_decode(_ctx, nb) != 0) break;
    }

    llama_sampler_free(chain);
    return result;
}

- (nullable NSArray<NSNumber *> *)embedding:(NSString *)text
                                      error:(NSError **)error {
    if (!self.isLoaded) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:20
                                     userInfo:@{NSLocalizedDescriptionKey: @"Model not loaded"}];
        }
        return nil;
    }

    const char *cText = text ? [text UTF8String] : "";
    const int textLen = (int)strlen(cText);

    // llama.cpp b8933: tokenize takes a vocab, not a model.
    const struct llama_vocab *vocab = llama_model_get_vocab(_model);

    int probe = llama_tokenize(vocab, cText, textLen,
                               NULL, 0, /*add_special=*/true, /*parse_special=*/false);
    int needed = probe < 0 ? -probe : probe;
    if (needed <= 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:21
                                     userInfo:@{NSLocalizedDescriptionKey: @"Tokenization produced no tokens"}];
        }
        return nil;
    }

    llama_token *tokens = (llama_token *)calloc((size_t)needed, sizeof(llama_token));
    if (tokens == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:21
                                     userInfo:@{NSLocalizedDescriptionKey: @"calloc failed"}];
        }
        return nil;
    }

    int actual = llama_tokenize(vocab, cText, textLen,
                                tokens, needed, /*add_special=*/true, /*parse_special=*/false);
    if (actual <= 0) {
        free(tokens);
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:21
                                     userInfo:@{NSLocalizedDescriptionKey: @"Tokenization failed"}];
        }
        return nil;
    }

    // llama.cpp b8933: llama_batch_get_one is (tokens, n_tokens) only.
    struct llama_batch batch = llama_batch_get_one(tokens, actual);
    if (llama_decode(_ctx, batch) != 0) {
        free(tokens);
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:22
                                     userInfo:@{NSLocalizedDescriptionKey: @"Decode failed"}];
        }
        return nil;
    }
    free(tokens);

    // llama.cpp b8933: llama_n_embd -> llama_model_n_embd.
    int n_embd = llama_model_n_embd(_model);
    if (n_embd <= 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:23
                                     userInfo:@{NSLocalizedDescriptionKey: @"llama_model_n_embd returned non-positive"}];
        }
        return nil;
    }
    const float *vec = llama_get_embeddings_seq(_ctx, 0);
    if (!vec) {
        // Fallback: llama_get_embeddings returns the last-decoded token's
        // embedding, valid when not in seq-mode. The seq variant prefers a
        // pooled / sequence-level vector when the context was loaded with
        // embedding pooling on; the plain variant is the best-effort fallback.
        vec = llama_get_embeddings(_ctx);
    }
    if (!vec) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:23
                                     userInfo:@{NSLocalizedDescriptionKey: @"Embedding pointer null"}];
        }
        return nil;
    }

    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)n_embd];
    for (int i = 0; i < n_embd; i++) {
        [result addObject:@(vec[i])];
    }
    return result;
}

@end
