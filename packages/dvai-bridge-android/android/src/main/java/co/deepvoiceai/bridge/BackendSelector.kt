package co.deepvoiceai.bridge

import java.io.File

/**
 * Auto-resolution rules for [BackendKind.Auto]. Pure function, no Android
 * runtime dependency — testable as a JVM unit test.
 *
 * The order below is the resolution priority. First matching rule wins:
 *   1. modelPath ends with `.task` and the file exists -> MediaPipe.
 *   2. modelPath ends with `.tflite` or `.litertlm`    -> LiteRT.
 *   3. Default (incl. .gguf and any unknown extension) -> Llama.
 *
 * Mirrors the iOS DVAIBridge BackendSelector logic (see
 * `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/BackendSelector.swift`)
 * — keep them in lockstep when adding new dispatch heuristics.
 */
object BackendSelector {
    fun resolve(opts: StartOptions): BackendKind {
        if (opts.backend != BackendKind.Auto) return opts.backend
        val path = opts.modelPath
        if (path != null) {
            if (path.endsWith(".task") && File(path).exists()) return BackendKind.MediaPipe
            if (path.endsWith(".tflite") || path.endsWith(".litertlm")) return BackendKind.LiteRT
        }
        return BackendKind.Llama
    }
}
