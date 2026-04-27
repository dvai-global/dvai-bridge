package co.deepvoiceai.bridge

/**
 * Inference backend selector. Mirrors the iOS DVAIBridge `BackendKind`
 * enum 1:1 in name and case order so cross-platform consumers can
 * reason about them identically.
 *
 * - [Auto]:      Pick the best backend for the supplied options at
 *                runtime. See [BackendSelector] for the resolution rules.
 * - [Llama]:     llama.cpp via android-llama-core. Universal `.gguf` support.
 * - [MediaPipe]: Google's MediaPipe LLM Inference (LiteRT-LM under the hood
 *                post-Phase 3B). Consumes `.task` checkpoints.
 * - [LiteRT]:    Bare LiteRT (TFLite successor) for `.tflite` / `.litertlm`
 *                Llama-style stateful checkpoints — Phase 3D's new backend.
 */
enum class BackendKind {
    Auto,
    Llama,
    MediaPipe,
    LiteRT,
}
