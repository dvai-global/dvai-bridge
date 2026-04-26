#import "LlamaCppBridge.h"
// Consumed via SPM .binaryTarget against build-apple/llama.xcframework
// (built by scripts/mac-side-prepare-xcframework.sh). Framework
// modulemap re-exports llama.h, ggml.h, ggml-alloc.h, ggml-backend.h,
// ggml-metal.h, ggml-cpu.h, ggml-blas.h, gguf.h.
#import <llama/llama.h>
// Multimodal (mtmd) is shipped as a sibling binaryTarget --
// build-apple/mtmd.xcframework. The framework's modulemap exposes
// mtmd.h and mtmd-helper.h; ggml.h / llama.h come from the llama
// framework imported above.
#import <mtmd/mtmd.h>
#import <mtmd/mtmd-helper.h>
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <string.h>

@implementation LlamaCppBridge {
    struct llama_model *_model;
    struct llama_context *_ctx;
    NSString *_currentModelPath;
    BOOL _embeddingMode;
    // Phase 2A Pass 2: real mtmd state.
    struct mtmd_context *_mtmdCtx;
    NSString *_currentMmprojPath;
}

- (instancetype)init {
    if ((self = [super init])) {
        _model = NULL;
        _ctx = NULL;
        _currentModelPath = nil;
        _embeddingMode = NO;
        _mtmdCtx = NULL;
        _currentMmprojPath = nil;
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
    // on-demand via -loadMmprojAtPath:error: by PluginState after the main
    // model is up. We don't auto-load here so that text-only flows keep their
    // simple init shape.
    (void)mmprojPath;

    _currentModelPath = [path copy];
    _embeddingMode = embeddingMode;
    return YES;
}

- (void)unload {
    // Multimodal projector outlives nothing past the main model -- if the
    // text model goes away, the mtmd_context (which holds a reference to
    // it) must go too. Unload the projector first.
    [self unloadMmproj];
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

#pragma mark - Internal sampling helper

// Greedy-sample up to maxTokens tokens starting from the current KV-cache
// state (n_past tokens already evaled). Returns the generated text. Used by
// both completePrompt: and completeMultimodalPrompt:.
- (NSString *)sampleGreedyUpToMaxTokens:(int)maxTokens
                                  vocab:(const struct llama_vocab *)vocab {
    struct llama_sampler_chain_params sp = llama_sampler_chain_default_params();
    struct llama_sampler *chain = llama_sampler_chain_init(sp);
    llama_sampler_chain_add(chain, llama_sampler_init_greedy());

    NSMutableString *result = [NSMutableString string];
    const llama_token eos = llama_vocab_eos(vocab);

    for (int i = 0; i < maxTokens; i++) {
        llama_token tokenId = llama_sampler_sample(chain, _ctx, -1);
        llama_sampler_accept(chain, tokenId);

        if (tokenId == eos) break;

        char buf[256] = {0};
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

    return [self sampleGreedyUpToMaxTokens:maxTokens vocab:vocab];
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

#pragma mark - Multimodal (mtmd) — Phase 2A Pass 2

- (BOOL)isMmprojLoaded {
    return _mtmdCtx != NULL;
}

- (BOOL)loadMmprojAtPath:(NSString *)mmprojPath
                   error:(NSError **)error {
    return [self loadMmprojAtPath:mmprojPath useGPU:YES error:error];
}

- (BOOL)loadMmprojAtPath:(NSString *)mmprojPath
                  useGPU:(BOOL)useGPU
                   error:(NSError **)error {
    if (mmprojPath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:30
                                     userInfo:@{NSLocalizedDescriptionKey: @"empty mmproj path"}];
        }
        return NO;
    }
    if (_model == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:31
                                     userInfo:@{NSLocalizedDescriptionKey: @"main model must be loaded before mmproj"}];
        }
        return NO;
    }
    [self unloadMmproj];

    struct mtmd_context_params params = mtmd_context_params_default();
    params.use_gpu = useGPU ? true : false;
    _mtmdCtx = mtmd_init_from_file([mmprojPath UTF8String], _model, params);
    if (_mtmdCtx == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:32
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"mtmd_init_from_file failed (mmproj incompatible with model?)"}];
        }
        return NO;
    }
    _currentMmprojPath = [mmprojPath copy];
    return YES;
}

- (void)unloadMmproj {
    if (_mtmdCtx != NULL) {
        mtmd_free(_mtmdCtx);
        _mtmdCtx = NULL;
    }
    _currentMmprojPath = nil;
}

- (BOOL)hasAudioEncoder {
    if (_mtmdCtx == NULL) return NO;
    return mtmd_support_audio(_mtmdCtx);
}

- (nullable NSString *)applyChatTemplate:(nullable NSString *)templateOverride
                                messages:(NSArray<NSDictionary<NSString *, NSString *> *> *)messages
                            addAssistant:(BOOL)addAssistant
                                   error:(NSError **)error {
    if (!self.isLoaded) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:40
                                     userInfo:@{NSLocalizedDescriptionKey: @"Model not loaded"}];
        }
        return nil;
    }
    NSUInteger n = messages.count;
    if (n == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:43
                                     userInfo:@{NSLocalizedDescriptionKey: @"messages array is empty"}];
        }
        return nil;
    }

    // Build llama_chat_message array. We strdup() each role/content so the
    // C-string lifetime is independent of any autorelease pool draining
    // mid-call. NSString.UTF8String returns a pointer with autorelease
    // lifetime, which is unsafe to hold across this multi-step call.
    struct llama_chat_message *chat = (struct llama_chat_message *)calloc(n, sizeof(struct llama_chat_message));
    if (!chat) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:44
                                     userInfo:@{NSLocalizedDescriptionKey: @"calloc failed"}];
        }
        return nil;
    }
    for (NSUInteger i = 0; i < n; i++) {
        NSDictionary *msg = messages[i];
        NSString *role = msg[@"role"];
        NSString *content = msg[@"content"];
        if (![role isKindOfClass:[NSString class]]) role = @"user";
        if (![content isKindOfClass:[NSString class]]) content = @"";
        chat[i].role = strdup([role UTF8String]);
        chat[i].content = strdup([content UTF8String]);
    }

    // Resolve template: explicit override > model's own > NULL (= built-in
    // default heuristic; may fail for unknown architectures).
    const char *tmpl = NULL;
    if (templateOverride.length > 0) {
        tmpl = [templateOverride UTF8String];
    } else {
        const char *modelTmpl = llama_model_chat_template(_model, NULL);
        if (modelTmpl) tmpl = modelTmpl;
    }

    // Probe size. llama_chat_apply_template returns the required bytes
    // (positive) when buf is too small, or a negative error code.
    int needed = llama_chat_apply_template(tmpl, chat, n, addAssistant, NULL, 0);
    if (needed <= 0) {
        for (NSUInteger i = 0; i < n; i++) {
            free((void *)chat[i].role);
            free((void *)chat[i].content);
        }
        free(chat);
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:41
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"llama_chat_apply_template probe failed (model has no chat template and none provided?)"}];
        }
        return nil;
    }
    char *buf = (char *)calloc((size_t)needed + 1, sizeof(char));
    if (!buf) {
        for (NSUInteger i = 0; i < n; i++) {
            free((void *)chat[i].role);
            free((void *)chat[i].content);
        }
        free(chat);
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:44
                                     userInfo:@{NSLocalizedDescriptionKey: @"calloc failed"}];
        }
        return nil;
    }
    int actual = llama_chat_apply_template(tmpl, chat, n, addAssistant, buf, needed + 1);
    NSString *result = nil;
    if (actual > 0) {
        result = [[NSString alloc] initWithBytes:buf length:(NSUInteger)actual encoding:NSUTF8StringEncoding];
    }
    for (NSUInteger i = 0; i < n; i++) {
        free((void *)chat[i].role);
        free((void *)chat[i].content);
    }
    free(chat);
    free(buf);

    if (!result) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:42
                                     userInfo:@{NSLocalizedDescriptionKey: @"llama_chat_apply_template failed"}];
        }
        return nil;
    }
    return result;
}

- (nullable NSString *)completeMultimodalPrompt:(NSString *)prompt
                                          media:(NSArray<NSData *> *)mediaInOrder
                                      maxTokens:(int)maxTokens
                                    temperature:(float)temperature
                                           topP:(float)topP
                                          error:(NSError **)error {
    (void)temperature;
    (void)topP;

    if (!self.isLoaded) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:50
                                     userInfo:@{NSLocalizedDescriptionKey: @"Model not loaded"}];
        }
        return nil;
    }
    if (_mtmdCtx == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:51
                                     userInfo:@{NSLocalizedDescriptionKey: @"mmproj not loaded"}];
        }
        return nil;
    }

    NSUInteger nMedia = mediaInOrder.count;

    // 1. Build bitmaps in declaration order. Each bitmap is auto-detected as
    //    image vs audio by mtmd_helper_bitmap_init_from_buf via magic bytes.
    mtmd_bitmap **bitmaps = NULL;
    if (nMedia > 0) {
        bitmaps = (mtmd_bitmap **)calloc(nMedia, sizeof(mtmd_bitmap *));
        if (!bitmaps) {
            if (error) {
                *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                             code:55
                                         userInfo:@{NSLocalizedDescriptionKey: @"calloc failed"}];
            }
            return nil;
        }
    }
    for (NSUInteger i = 0; i < nMedia; i++) {
        NSData *bytes = mediaInOrder[i];
        bitmaps[i] = mtmd_helper_bitmap_init_from_buf(_mtmdCtx,
                                                     (const unsigned char *)bytes.bytes,
                                                     (size_t)bytes.length);
        if (bitmaps[i] == NULL) {
            for (NSUInteger j = 0; j < i; j++) mtmd_bitmap_free(bitmaps[j]);
            free(bitmaps);
            if (error) {
                *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                             code:52
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"mtmd_helper_bitmap_init_from_buf failed for media[%lu]",
                                                     (unsigned long)i]}];
            }
            return nil;
        }
    }

    // 2. Tokenize. mtmd_tokenize matches markers in the prompt against the
    //    bitmap array in order.
    mtmd_input_chunks *chunks = mtmd_input_chunks_init();
    if (!chunks) {
        for (NSUInteger i = 0; i < nMedia; i++) mtmd_bitmap_free(bitmaps[i]);
        free(bitmaps);
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:55
                                     userInfo:@{NSLocalizedDescriptionKey: @"mtmd_input_chunks_init failed"}];
        }
        return nil;
    }
    struct mtmd_input_text input_text;
    input_text.text = prompt ? [prompt UTF8String] : "";
    // The chat template already added BOS; don't add it again.
    input_text.add_special = false;
    input_text.parse_special = true;
    int32_t tok_rc = mtmd_tokenize(_mtmdCtx, chunks, &input_text,
                                   (const mtmd_bitmap **)bitmaps, (size_t)nMedia);
    // Per mtmd.h: mtmd_tokenize copies what it needs out of bitmaps; safe to
    // free immediately after the call returns.
    for (NSUInteger i = 0; i < nMedia; i++) mtmd_bitmap_free(bitmaps[i]);
    free(bitmaps);
    if (tok_rc != 0) {
        mtmd_input_chunks_free(chunks);
        if (error) {
            NSString *msg = (tok_rc == 1)
                ? @"mtmd_tokenize: marker count does not match media count"
                : (tok_rc == 2)
                    ? @"mtmd_tokenize: image preprocessing error"
                    : [NSString stringWithFormat:@"mtmd_tokenize failed (rc=%d)", tok_rc];
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:53
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return nil;
    }

    // 3. Eval all chunks.
    llama_pos n_past = 0;
    llama_pos new_n_past = 0;
    int32_t eval_rc = mtmd_helper_eval_chunks(_mtmdCtx, _ctx, chunks,
                                              n_past,
                                              /*seq_id=*/0,
                                              /*n_batch=*/512,
                                              /*logits_last=*/true,
                                              &new_n_past);
    mtmd_input_chunks_free(chunks);
    if (eval_rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"DVAIBridgeLlama"
                                         code:54
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"mtmd_helper_eval_chunks failed (rc=%d)",
                                                 eval_rc]}];
        }
        return nil;
    }

    // 4. Sampling loop (greedy). The KV cache now reflects all evaled chunks;
    //    each sampled token is appended as a 1-token batch via the helper.
    const struct llama_vocab *vocab = llama_model_get_vocab(_model);
    return [self sampleGreedyUpToMaxTokens:maxTokens vocab:vocab];
}

@end
