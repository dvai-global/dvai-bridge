// android/src/main/cpp/jni-bridge.cpp
// Real llama.cpp JNI bridge for LlamaCppBridge (Task 31).
//
// Mirrors the iOS DVAICapacitorLlamaObjC LlamaCppBridge.mm implementation:
//  - load/unload manage llama_model + llama_context lifetimes
//  - completePrompt does greedy generation via the new sampler-chain API
//    (llama_sample_token_greedy was removed upstream; we use chain_init +
//    init_greedy + sampler_sample/accept and free the chain at the end).
//
// Temperature and top-p are accepted but ignored for now; Task 36 will wire
// them in by extending the sampler chain. The mmproj path is recorded by the
// PluginState elsewhere; multimodal projection is loaded in Task 35.

#include <jni.h>
#include <android/log.h>
#include <string>
#include <vector>
#include <cstring>

#include "llama.h"

#define LOG_TAG "DVAIBridgeLlama"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

struct LlamaContextHolder {
    llama_model*   model = nullptr;
    llama_context* ctx   = nullptr;
    std::string    model_path;
    bool           embedding_mode = false;
};

namespace {

// Free model + ctx and reset bookkeeping. Safe to call repeatedly.
void unload_holder(LlamaContextHolder* h) {
    if (!h) return;
    if (h->ctx) {
        llama_free(h->ctx);
        h->ctx = nullptr;
    }
    if (h->model) {
        llama_free_model(h->model);
        h->model = nullptr;
    }
    h->model_path.clear();
    h->embedding_mode = false;
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

    // mmproj path is recorded by Kotlin/PluginState; loading the projector
    // happens in Task 35 (multimodal pipeline). Silence the unused warning.
    (void)jMmprojPath;

    // Now safe to free prior state and load fresh -- validation passed so we
    // won't destroy a previously-loaded model just because the path was bad.
    // Mirrors LlamaCppBridge.mm on iOS, which returns early before [self unload].
    unload_holder(h);

    llama_backend_init();

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = gpuLayers;

    h->model = llama_load_model_from_file(path.c_str(), mp);
    if (h->model == nullptr) {
        LOGE("llama_load_model_from_file failed for %s", path.c_str());
        return JNI_FALSE;
    }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx           = static_cast<uint32_t>(contextSize);
    cp.n_threads       = threads;
    cp.n_threads_batch = threads;
    cp.embeddings      = (embeddingMode == JNI_TRUE);

    h->ctx = llama_new_context_with_model(h->model, cp);
    if (h->ctx == nullptr) {
        LOGE("llama_new_context_with_model failed");
        llama_free_model(h->model);
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

// Smoke ping for verifying JNI linkage in instrumented tests.
extern "C" JNIEXPORT void JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeSmoke(
        JNIEnv* /*env*/, jobject /*thiz*/) {
    LOGI("DVAIBridgeLlama JNI smoke ping");
}

// Greedy completion. Temperature and top-p are accepted but ignored for now;
// Task 36 will extend the sampler chain to honour them.
extern "C" JNIEXPORT jstring JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeCompletePrompt(
        JNIEnv* env, jobject /*thiz*/, jlong handle,
        jstring jPrompt, jint maxTokens, jfloat temperature, jfloat topP) {
    (void)temperature;
    (void)topP;

    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (!h || !h->ctx || !h->model) {
        return nullptr;
    }
    if (jPrompt == nullptr) {
        return nullptr;
    }

    const char* cPrompt = env->GetStringUTFChars(jPrompt, nullptr);
    if (cPrompt == nullptr) return nullptr;
    std::string prompt(cPrompt);
    env->ReleaseStringUTFChars(jPrompt, cPrompt);

    const int promptLen = static_cast<int>(prompt.size());

    // Two-phase tokenize: probe with a NULL/0 buffer; the negated return is
    // the required token count. This is robust for non-ASCII prompts where
    // (size + 1) is NOT a safe upper bound.
    int probe = llama_tokenize(h->model, prompt.c_str(), promptLen,
                               /*tokens=*/nullptr, /*n_tokens_max=*/0,
                               /*add_special=*/true, /*parse_special=*/false);
    int needed = probe < 0 ? -probe : probe;
    if (needed <= 0) {
        LOGE("nativeCompletePrompt: tokenize probe returned %d", probe);
        return nullptr;
    }

    std::vector<llama_token> tokens(static_cast<size_t>(needed));
    int actual = llama_tokenize(h->model, prompt.c_str(), promptLen,
                                tokens.data(), needed,
                                /*add_special=*/true, /*parse_special=*/false);
    if (actual <= 0) {
        LOGE("nativeCompletePrompt: tokenize failed (%d)", actual);
        return nullptr;
    }

    // Decode the prompt.
    {
        llama_batch batch = llama_batch_get_one(tokens.data(), actual, 0, 0);
        if (llama_decode(h->ctx, batch) != 0) {
            LOGE("nativeCompletePrompt: prompt decode failed");
            return nullptr;
        }
    }

    // Build a greedy sampler chain. The chain owns the greedy sampler and
    // frees it when llama_sampler_free(chain) is called -- do NOT free
    // llama_sampler_init_greedy() separately.
    llama_sampler_chain_params sp = llama_sampler_chain_default_params();
    llama_sampler* chain = llama_sampler_chain_init(sp);
    if (chain == nullptr) {
        LOGE("nativeCompletePrompt: sampler chain init failed");
        return nullptr;
    }
    llama_sampler_chain_add(chain, llama_sampler_init_greedy());

    std::string out;
    out.reserve(256);
    const llama_token eos = llama_token_eos(h->model);
    int n_cur = actual;

    for (int i = 0; i < maxTokens; i++) {
        llama_token tokenId = llama_sampler_sample(chain, h->ctx, -1);
        llama_sampler_accept(chain, tokenId);

        if (tokenId == eos) break;

        char buf[256] = {0};
        int wrote = llama_token_to_piece(h->model, tokenId, buf,
                                         static_cast<int>(sizeof(buf)),
                                         /*lstrip=*/0, /*special=*/false);
        if (wrote > 0) {
            // token_to_piece does NOT null-terminate; append explicit length.
            out.append(buf, static_cast<size_t>(wrote));
        }
        // wrote == 0 -> nothing to append; wrote < 0 -> buffer too small for
        // this piece, which shouldn't happen with a 256-byte buffer for typical
        // BPE pieces. Skip and continue.

        llama_token next = tokenId;
        llama_batch nb = llama_batch_get_one(&next, 1, n_cur, 0);
        if (llama_decode(h->ctx, nb) != 0) {
            LOGE("nativeCompletePrompt: per-token decode failed at i=%d", i);
            break;
        }
        n_cur++;
    }

    llama_sampler_free(chain);
    return env->NewStringUTF(out.c_str());
}
