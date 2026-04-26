// android/src/main/cpp/jni-bridge.cpp
// llama.cpp + mtmd JNI bridge for LlamaCppBridge.
//
// Mirrors the iOS DVAICapacitorLlamaObjC LlamaCppBridge.mm implementation:
//  - load/unload manage llama_model + llama_context lifetimes
//  - completePrompt does greedy generation via the new sampler-chain API
//  - Phase 2A Pass 2: mtmd integration for vision + audio multimodal eval
//    (mtmd_init_from_file, mtmd_helper_bitmap_init_from_buf, mtmd_tokenize,
//    mtmd_helper_eval_chunks).

#include <jni.h>
#include <android/log.h>
#include <string>
#include <vector>
#include <cstring>
#include <cstdlib>

#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#define LOG_TAG "DVAIBridgeLlama"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

struct LlamaContextHolder {
    llama_model*   model = nullptr;
    llama_context* ctx   = nullptr;
    std::string    model_path;
    bool           embedding_mode = false;
    // Phase 2A Pass 2: real mtmd state.
    mtmd_context*  mtmd_ctx = nullptr;
    std::string    mmproj_path;
};

namespace {

// Free model + ctx and reset bookkeeping. Safe to call repeatedly.
void unload_holder(LlamaContextHolder* h) {
    if (!h) return;
    if (h->mtmd_ctx) {
        mtmd_free(h->mtmd_ctx);
        h->mtmd_ctx = nullptr;
    }
    h->mmproj_path.clear();
    if (h->ctx) {
        llama_free(h->ctx);
        h->ctx = nullptr;
    }
    if (h->model) {
        // llama.cpp b8933: llama_free_model -> llama_model_free.
        llama_model_free(h->model);
        h->model = nullptr;
    }
    h->model_path.clear();
    h->embedding_mode = false;
}

// Greedy-sample up to max_tokens tokens from the current KV-cache state.
// Used by both completePrompt and completeMultimodalPrompt after their
// respective initialization steps.
std::string sample_greedy(LlamaContextHolder* h, int max_tokens, const llama_vocab* vocab) {
    llama_sampler_chain_params sp = llama_sampler_chain_default_params();
    llama_sampler* chain = llama_sampler_chain_init(sp);
    if (!chain) {
        LOGE("sample_greedy: sampler_chain_init failed");
        return std::string();
    }
    llama_sampler_chain_add(chain, llama_sampler_init_greedy());

    std::string out;
    out.reserve(256);
    const llama_token eos = llama_vocab_eos(vocab);

    for (int i = 0; i < max_tokens; i++) {
        llama_token tokenId = llama_sampler_sample(chain, h->ctx, -1);
        llama_sampler_accept(chain, tokenId);
        if (tokenId == eos) break;

        char buf[256] = {0};
        int wrote = llama_token_to_piece(vocab, tokenId, buf,
                                         static_cast<int>(sizeof(buf)),
                                         /*lstrip=*/0, /*special=*/false);
        if (wrote > 0) {
            out.append(buf, static_cast<size_t>(wrote));
        }

        llama_token next = tokenId;
        llama_batch nb = llama_batch_get_one(&next, 1);
        if (llama_decode(h->ctx, nb) != 0) {
            LOGE("sample_greedy: per-token decode failed at i=%d", i);
            break;
        }
    }
    llama_sampler_free(chain);
    return out;
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeCreate(
        JNIEnv* /*env*/, jobject /*thiz*/) {
    return reinterpret_cast<jlong>(new LlamaContextHolder());
}

extern "C" JNIEXPORT void JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeDestroy(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (!h) return;
    unload_holder(h);
    delete h;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeLoadModel(
        JNIEnv* env, jobject /*thiz*/, jlong handle,
        jstring jPath, jstring jMmprojPath,
        jint gpuLayers, jint contextSize, jint threads, jboolean embeddingMode) {
    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (!h) return JNI_FALSE;
    if (jPath == nullptr) return JNI_FALSE;

    const char* cPath = env->GetStringUTFChars(jPath, nullptr);
    if (cPath == nullptr) return JNI_FALSE;
    std::string path(cPath);
    env->ReleaseStringUTFChars(jPath, cPath);

    if (path.empty()) return JNI_FALSE;

    // mmproj path is loaded on-demand via nativeLoadMmproj after the main
    // model is up. We don't auto-load here so text-only flows keep their
    // simple init shape.
    (void)jMmprojPath;

    unload_holder(h);

    llama_backend_init();

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = gpuLayers;

    h->model = llama_model_load_from_file(path.c_str(), mp);
    if (h->model == nullptr) {
        LOGE("llama_model_load_from_file failed for %s", path.c_str());
        return JNI_FALSE;
    }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx           = static_cast<uint32_t>(contextSize);
    cp.n_threads       = threads;
    cp.n_threads_batch = threads;
    cp.embeddings      = (embeddingMode == JNI_TRUE);

    h->ctx = llama_init_from_model(h->model, cp);
    if (h->ctx == nullptr) {
        LOGE("llama_init_from_model failed");
        llama_model_free(h->model);
        h->model = nullptr;
        return JNI_FALSE;
    }

    h->model_path     = path;
    h->embedding_mode = (embeddingMode == JNI_TRUE);
    LOGI("llama.cpp model loaded: %s (n_ctx=%d threads=%d gpu_layers=%d embed=%d)",
         path.c_str(), contextSize, threads, gpuLayers, (int)h->embedding_mode);
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeUnload(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    unload_holder(h);
}

extern "C" JNIEXPORT jstring JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeVersionString(
        JNIEnv* env, jobject /*thiz*/, jlong /*handle*/) {
    const char* info = llama_print_system_info();
    std::string out = "llama.cpp ";
    if (info) out.append(info);
    return env->NewStringUTF(out.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeSmoke(
        JNIEnv* /*env*/, jobject /*thiz*/) {
    LOGI("DVAIBridgeLlama JNI smoke ping");
}

extern "C" JNIEXPORT jstring JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeCompletePrompt(
        JNIEnv* env, jobject /*thiz*/, jlong handle,
        jstring jPrompt, jint maxTokens, jfloat temperature, jfloat topP) {
    (void)temperature;
    (void)topP;

    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (!h || !h->ctx || !h->model) return nullptr;
    if (jPrompt == nullptr) return nullptr;

    const char* cPrompt = env->GetStringUTFChars(jPrompt, nullptr);
    if (cPrompt == nullptr) return nullptr;
    std::string prompt(cPrompt);
    env->ReleaseStringUTFChars(jPrompt, cPrompt);

    const int promptLen = static_cast<int>(prompt.size());
    const llama_vocab* vocab = llama_model_get_vocab(h->model);

    int probe = llama_tokenize(vocab, prompt.c_str(), promptLen,
                               nullptr, 0, /*add_special=*/true, /*parse_special=*/false);
    int needed = probe < 0 ? -probe : probe;
    if (needed <= 0) {
        LOGE("nativeCompletePrompt: tokenize probe returned %d", probe);
        return nullptr;
    }

    std::vector<llama_token> tokens(static_cast<size_t>(needed));
    int actual = llama_tokenize(vocab, prompt.c_str(), promptLen,
                                tokens.data(), needed,
                                /*add_special=*/true, /*parse_special=*/false);
    if (actual <= 0) {
        LOGE("nativeCompletePrompt: tokenize failed (%d)", actual);
        return nullptr;
    }

    {
        llama_batch batch = llama_batch_get_one(tokens.data(), actual);
        if (llama_decode(h->ctx, batch) != 0) {
            LOGE("nativeCompletePrompt: prompt decode failed");
            return nullptr;
        }
    }

    std::string out = sample_greedy(h, maxTokens, vocab);
    return env->NewStringUTF(out.c_str());
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeEmbedding(
        JNIEnv* env, jobject /*thiz*/, jlong handle, jstring jText) {
    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (!h || !h->ctx || !h->model) return nullptr;
    if (jText == nullptr) return nullptr;

    const char* cText = env->GetStringUTFChars(jText, nullptr);
    if (cText == nullptr) return nullptr;
    std::string text(cText);
    env->ReleaseStringUTFChars(jText, cText);

    const int textLen = static_cast<int>(text.size());
    const llama_vocab* vocab = llama_model_get_vocab(h->model);

    int probe = llama_tokenize(vocab, text.c_str(), textLen,
                               nullptr, 0, /*add_special=*/true, /*parse_special=*/false);
    int needed = probe < 0 ? -probe : probe;
    if (needed <= 0) {
        LOGE("nativeEmbedding: tokenize probe returned %d", probe);
        return nullptr;
    }

    std::vector<llama_token> tokens(static_cast<size_t>(needed));
    int actual = llama_tokenize(vocab, text.c_str(), textLen,
                                tokens.data(), needed,
                                /*add_special=*/true, /*parse_special=*/false);
    if (actual <= 0) {
        LOGE("nativeEmbedding: tokenize failed (%d)", actual);
        return nullptr;
    }

    {
        llama_batch batch = llama_batch_get_one(tokens.data(), actual);
        if (llama_decode(h->ctx, batch) != 0) {
            LOGE("nativeEmbedding: decode failed");
            return nullptr;
        }
    }

    int n_embd = llama_model_n_embd(h->model);
    if (n_embd <= 0) {
        LOGE("nativeEmbedding: llama_model_n_embd returned %d", n_embd);
        return nullptr;
    }
    const float* vec = llama_get_embeddings_seq(h->ctx, 0);
    if (!vec) vec = llama_get_embeddings(h->ctx);
    if (!vec) {
        LOGE("nativeEmbedding: embedding pointer null");
        return nullptr;
    }

    jfloatArray out = env->NewFloatArray(n_embd);
    if (!out) return nullptr;
    env->SetFloatArrayRegion(out, 0, n_embd, vec);
    return out;
}

// =============================================================================
// Multimodal (mtmd) — Phase 2A Pass 2
// =============================================================================

extern "C" JNIEXPORT jboolean JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeLoadMmproj(
        JNIEnv* env, jobject /*thiz*/, jlong handle, jstring jMmprojPath) {
    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (!h || h->model == nullptr) return JNI_FALSE;
    if (jMmprojPath == nullptr) return JNI_FALSE;

    const char* cPath = env->GetStringUTFChars(jMmprojPath, nullptr);
    if (cPath == nullptr) return JNI_FALSE;
    std::string path(cPath);
    env->ReleaseStringUTFChars(jMmprojPath, cPath);

    if (path.empty()) return JNI_FALSE;

    // Drop any previously-loaded projector before recording the new path.
    if (h->mtmd_ctx) {
        mtmd_free(h->mtmd_ctx);
        h->mtmd_ctx = nullptr;
    }

    mtmd_context_params params = mtmd_context_params_default();
    h->mtmd_ctx = mtmd_init_from_file(path.c_str(), h->model, params);
    if (h->mtmd_ctx == nullptr) {
        LOGE("mtmd_init_from_file failed for %s", path.c_str());
        h->mmproj_path.clear();
        return JNI_FALSE;
    }
    h->mmproj_path = path;
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeUnloadMmproj(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (!h) return;
    if (h->mtmd_ctx) {
        mtmd_free(h->mtmd_ctx);
        h->mtmd_ctx = nullptr;
    }
    h->mmproj_path.clear();
}

extern "C" JNIEXPORT jboolean JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeIsMmprojLoaded(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (!h) return JNI_FALSE;
    return (h->mtmd_ctx != nullptr) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeHasAudioEncoder(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (!h || h->mtmd_ctx == nullptr) return JNI_FALSE;
    return mtmd_support_audio(h->mtmd_ctx) ? JNI_TRUE : JNI_FALSE;
}

// Apply a chat template via llama_chat_apply_template. Messages are passed
// as parallel String[] arrays for roles + contents; templateOverride may be
// null/empty in which case we look up the model's bundled chat template
// (NULL falls through to llama.cpp's built-in heuristic).
extern "C" JNIEXPORT jstring JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeApplyChatTemplate(
        JNIEnv* env, jobject /*thiz*/, jlong handle,
        jstring jTemplateOverride,
        jobjectArray jRoles, jobjectArray jContents,
        jboolean addAssistant) {
    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (!h || !h->model) {
        LOGE("nativeApplyChatTemplate: model not loaded");
        return nullptr;
    }
    if (jRoles == nullptr || jContents == nullptr) {
        LOGE("nativeApplyChatTemplate: roles/contents null");
        return nullptr;
    }
    jsize nRoles = env->GetArrayLength(jRoles);
    jsize nContents = env->GetArrayLength(jContents);
    if (nRoles != nContents || nRoles <= 0) {
        LOGE("nativeApplyChatTemplate: array size mismatch (%d vs %d)", nRoles, nContents);
        return nullptr;
    }

    // Materialize C strings.
    std::vector<std::string> roles((size_t)nRoles);
    std::vector<std::string> contents((size_t)nRoles);
    for (jsize i = 0; i < nRoles; i++) {
        auto rs = (jstring)env->GetObjectArrayElement(jRoles, i);
        auto cs = (jstring)env->GetObjectArrayElement(jContents, i);
        const char* rc = rs ? env->GetStringUTFChars(rs, nullptr) : "";
        const char* cc = cs ? env->GetStringUTFChars(cs, nullptr) : "";
        roles[(size_t)i]    = rc ? std::string(rc) : std::string();
        contents[(size_t)i] = cc ? std::string(cc) : std::string();
        if (rs && rc) env->ReleaseStringUTFChars(rs, rc);
        if (cs && cc) env->ReleaseStringUTFChars(cs, cc);
        if (rs) env->DeleteLocalRef(rs);
        if (cs) env->DeleteLocalRef(cs);
    }

    std::vector<llama_chat_message> chat((size_t)nRoles);
    for (size_t i = 0; i < (size_t)nRoles; i++) {
        chat[i].role    = roles[i].c_str();
        chat[i].content = contents[i].c_str();
    }

    // Resolve template. Empty/null override -> model's bundled template
    // -> NULL (llama.cpp's heuristic; may fail for unknown architectures).
    std::string tmplStorage;
    const char* tmpl = nullptr;
    if (jTemplateOverride != nullptr) {
        const char* override_c = env->GetStringUTFChars(jTemplateOverride, nullptr);
        if (override_c && override_c[0] != '\0') {
            tmplStorage = override_c;
            tmpl = tmplStorage.c_str();
        }
        if (override_c) env->ReleaseStringUTFChars(jTemplateOverride, override_c);
    }
    if (tmpl == nullptr) {
        const char* modelTmpl = llama_model_chat_template(h->model, nullptr);
        if (modelTmpl) tmpl = modelTmpl;
    }

    int needed = llama_chat_apply_template(tmpl, chat.data(), chat.size(),
                                           addAssistant == JNI_TRUE,
                                           nullptr, 0);
    if (needed <= 0) {
        LOGE("nativeApplyChatTemplate: probe failed (%d)", needed);
        return nullptr;
    }
    std::vector<char> buf((size_t)needed + 1, 0);
    int actual = llama_chat_apply_template(tmpl, chat.data(), chat.size(),
                                           addAssistant == JNI_TRUE,
                                           buf.data(), needed + 1);
    if (actual <= 0) {
        LOGE("nativeApplyChatTemplate: render failed (%d)", actual);
        return nullptr;
    }
    return env->NewStringUTF(std::string(buf.data(), (size_t)actual).c_str());
}

// Multimodal completion. media is a jobjectArray of byte[] (one per media
// item, in declaration order matching the <__media__> markers in prompt).
extern "C" JNIEXPORT jstring JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeCompleteMultimodalPrompt(
        JNIEnv* env, jobject /*thiz*/, jlong handle,
        jstring jPrompt, jobjectArray jMediaArray,
        jint maxTokens, jfloat temperature, jfloat topP) {
    (void)temperature;
    (void)topP;

    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (!h || !h->ctx || !h->model) {
        LOGE("nativeCompleteMultimodalPrompt: model not loaded");
        return nullptr;
    }
    if (h->mtmd_ctx == nullptr) {
        LOGE("nativeCompleteMultimodalPrompt: mmproj not loaded");
        return nullptr;
    }
    if (jPrompt == nullptr) return nullptr;

    const char* cPrompt = env->GetStringUTFChars(jPrompt, nullptr);
    if (cPrompt == nullptr) return nullptr;
    std::string prompt(cPrompt);
    env->ReleaseStringUTFChars(jPrompt, cPrompt);

    jsize nMedia = (jMediaArray != nullptr) ? env->GetArrayLength(jMediaArray) : 0;

    // 1. Build bitmaps.
    std::vector<mtmd_bitmap*> bitmaps((size_t)nMedia, nullptr);
    bool bitmap_failed = false;
    for (jsize i = 0; i < nMedia; i++) {
        auto barr = (jbyteArray)env->GetObjectArrayElement(jMediaArray, i);
        if (barr == nullptr) {
            LOGE("nativeCompleteMultimodalPrompt: media[%d] is null", i);
            bitmap_failed = true;
            break;
        }
        jsize len = env->GetArrayLength(barr);
        jbyte* data = env->GetByteArrayElements(barr, nullptr);
        if (data == nullptr) {
            env->DeleteLocalRef(barr);
            bitmap_failed = true;
            break;
        }
        bitmaps[(size_t)i] = mtmd_helper_bitmap_init_from_buf(
            h->mtmd_ctx,
            reinterpret_cast<const unsigned char*>(data),
            (size_t)len);
        env->ReleaseByteArrayElements(barr, data, JNI_ABORT);
        env->DeleteLocalRef(barr);
        if (bitmaps[(size_t)i] == nullptr) {
            LOGE("mtmd_helper_bitmap_init_from_buf failed for media[%d]", i);
            bitmap_failed = true;
            break;
        }
    }
    if (bitmap_failed) {
        for (auto* b : bitmaps) {
            if (b) mtmd_bitmap_free(b);
        }
        return nullptr;
    }

    // 2. Tokenize.
    mtmd_input_chunks* chunks = mtmd_input_chunks_init();
    if (!chunks) {
        for (auto* b : bitmaps) mtmd_bitmap_free(b);
        LOGE("mtmd_input_chunks_init failed");
        return nullptr;
    }
    mtmd_input_text input_text;
    input_text.text = prompt.c_str();
    input_text.add_special = false;   // chat template already added BOS
    input_text.parse_special = true;
    int32_t tok_rc = mtmd_tokenize(h->mtmd_ctx, chunks, &input_text,
                                   const_cast<const mtmd_bitmap**>(bitmaps.data()),
                                   bitmaps.size());
    // mtmd_tokenize copies what it needs; bitmaps can be freed now.
    for (auto* b : bitmaps) mtmd_bitmap_free(b);
    if (tok_rc != 0) {
        mtmd_input_chunks_free(chunks);
        LOGE("mtmd_tokenize failed (rc=%d)", tok_rc);
        return nullptr;
    }

    // 3. Eval all chunks.
    llama_pos n_past = 0;
    llama_pos new_n_past = 0;
    int32_t eval_rc = mtmd_helper_eval_chunks(h->mtmd_ctx, h->ctx, chunks,
                                              n_past, /*seq_id=*/0,
                                              /*n_batch=*/512,
                                              /*logits_last=*/true,
                                              &new_n_past);
    mtmd_input_chunks_free(chunks);
    if (eval_rc != 0) {
        LOGE("mtmd_helper_eval_chunks failed (rc=%d)", eval_rc);
        return nullptr;
    }

    // 4. Greedy sampling.
    const llama_vocab* vocab = llama_model_get_vocab(h->model);
    std::string out = sample_greedy(h, maxTokens, vocab);
    return env->NewStringUTF(out.c_str());
}
