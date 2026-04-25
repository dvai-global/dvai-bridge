// android/src/main/cpp/jni-bridge.cpp
// Minimal JNI smoke ping. Real bridge methods land in Task 31.
#include <jni.h>
#include <android/log.h>

#define LOG_TAG "DVAIBridgeLlama"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

extern "C" JNIEXPORT void JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeSmoke(JNIEnv *env, jobject /* this */) {
    LOGI("DVAIBridgeLlama JNI smoke ping");
}
