// android/src/main/cpp/jni-bridge.cpp
// Stub JNI methods for LlamaCppBridge. Real llama.cpp integration lands in Task 31.
#include <jni.h>
#include <android/log.h>
#include <string>

#define LOG_TAG "DVAIBridgeLlama"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

struct LlamaContextHolder {
    bool loaded = false;
    std::string model_path;
    bool embedding_mode = false;
};

extern "C" JNIEXPORT jlong JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeCreate(
        JNIEnv* /*env*/, jobject /*thiz*/) {
    return (jlong)(new LlamaContextHolder());
}

extern "C" JNIEXPORT void JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeDestroy(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (h) delete h;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeLoadModel(
        JNIEnv* env, jobject /*thiz*/, jlong handle,
        jstring jPath, jstring /*jMmprojPath*/,
        jint /*gpuLayers*/, jint /*contextSize*/, jint /*threads*/, jboolean embeddingMode) {
    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (!h) return JNI_FALSE;

    if (jPath == nullptr) return JNI_FALSE;
    const char* cPath = env->GetStringUTFChars(jPath, nullptr);
    if (cPath == nullptr) return JNI_FALSE;
    std::string path(cPath);
    env->ReleaseStringUTFChars(jPath, cPath);
    if (path.empty()) return JNI_FALSE;

    // Stub: just record state. Task 31 replaces this with real llama.cpp calls.
    h->model_path = path;
    h->embedding_mode = (embeddingMode == JNI_TRUE);
    h->loaded = true;
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeUnload(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto* h = reinterpret_cast<LlamaContextHolder*>(handle);
    if (h) {
        h->loaded = false;
        h->model_path.clear();
        h->embedding_mode = false;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeVersionString(
        JNIEnv* env, jobject /*thiz*/, jlong /*handle*/) {
    return env->NewStringUTF("llama.cpp-stub-android-0.1");
}

// Smoke ping for verifying JNI linkage in instrumented tests.
extern "C" JNIEXPORT void JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeSmoke(
        JNIEnv* /*env*/, jobject /*thiz*/) {
    LOGI("DVAIBridgeLlama JNI smoke ping");
}
