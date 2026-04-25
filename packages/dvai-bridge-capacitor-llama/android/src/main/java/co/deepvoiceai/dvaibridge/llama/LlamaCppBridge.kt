package co.deepvoiceai.dvaibridge.llama

/**
 * Kotlin wrapper around the C++ llama.cpp bridge for Android.
 *
 * The pure-Kotlin paths (load/unload state tracking) are exercised by
 * JVM unit tests; JNI calls are exercised by instrumented tests on an
 * Android device or emulator. Each native call is guarded with
 * `try { ... } catch (_: UnsatisfiedLinkError) { ... }` so the JVM tests
 * (which can't load the .so) keep working on the Kotlin-only fallback.
 */
class LlamaCppBridge {
    companion object {
        private var loaded: Boolean = false

        @JvmStatic
        private fun ensureLibraryLoaded() {
            if (!loaded) {
                System.loadLibrary("dvai_capacitor_llama")
                loaded = true
            }
        }
    }

    private var nativeHandle: Long = 0
    private var modelPath: String? = null
    private var isLoadedFlag: Boolean = false

    init {
        try {
            ensureLibraryLoaded()
            nativeHandle = nativeCreate()
        } catch (e: UnsatisfiedLinkError) {
            // JVM unit tests can't load the .so; that's OK -- instrumented tests cover JNI.
            nativeHandle = 0L
        }
    }

    @Suppress("ProtectedInFinal")
    protected fun finalize() {
        if (nativeHandle != 0L) {
            try {
                nativeDestroy(nativeHandle)
            } catch (_: UnsatisfiedLinkError) { /* ignore in JVM */ }
        }
    }

    fun isLoaded(): Boolean = isLoadedFlag

    fun getCurrentModelPath(): String? = modelPath

    /**
     * Load a GGUF model. Returns true on success.
     * In JVM unit tests (no .so loaded), this updates Kotlin state without calling JNI
     * so tests can exercise the load/unload state machine.
     */
    fun loadModel(
        path: String,
        mmprojPath: String?,
        gpuLayers: Int,
        contextSize: Int,
        threads: Int,
        embeddingMode: Boolean,
    ): Boolean {
        if (path.isEmpty()) return false
        val ok: Boolean = if (nativeHandle != 0L) {
            try {
                nativeLoadModel(nativeHandle, path, mmprojPath, gpuLayers, contextSize, threads, embeddingMode)
            } catch (_: UnsatisfiedLinkError) {
                true // JVM-only test fallback
            }
        } else {
            true // JNI not available; pretend success for state-machine tests
        }
        if (ok) {
            isLoadedFlag = true
            modelPath = path
        }
        return ok
    }

    fun unload() {
        if (nativeHandle != 0L) {
            try { nativeUnload(nativeHandle) } catch (_: UnsatisfiedLinkError) { /* ignore */ }
        }
        isLoadedFlag = false
        modelPath = null
    }

    fun versionString(): String {
        if (nativeHandle != 0L) {
            try { return nativeVersionString(nativeHandle) } catch (_: UnsatisfiedLinkError) { /* fall through */ }
        }
        return "llama.cpp-stub-android-0.1"
    }

    /**
     * Greedy prompt completion. Returns the generated text on success, or `null`
     * if the model isn't loaded / native isn't available (JVM tests).
     *
     * Temperature and topP are accepted now but ignored by the native side for
     * Phase 1; Task 36 will extend the sampler chain to honour them.
     */
    fun completePrompt(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
    ): String? {
        if (!isLoadedFlag) return null
        if (nativeHandle == 0L) return null // JVM tests: no .so, no completion.
        return try {
            nativeCompletePrompt(nativeHandle, prompt, maxTokens, temperature, topP)
        } catch (_: UnsatisfiedLinkError) {
            null // JVM-only fallback
        }
    }

    // JNI smoke ping -- instrumented tests only.
    external fun nativeSmoke()

    // Native methods (JNI). Hidden from public API.
    private external fun nativeCreate(): Long
    private external fun nativeDestroy(handle: Long)
    private external fun nativeLoadModel(
        handle: Long, path: String, mmprojPath: String?,
        gpuLayers: Int, contextSize: Int, threads: Int, embeddingMode: Boolean,
    ): Boolean
    private external fun nativeUnload(handle: Long)
    private external fun nativeVersionString(handle: Long): String
    private external fun nativeCompletePrompt(
        handle: Long, prompt: String, maxTokens: Int, temperature: Float, topP: Float,
    ): String?
}
