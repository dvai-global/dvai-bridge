package co.deepvoiceai.dvaibridge.llama

/**
 * Test seam over the JNI-backed bridge. Concrete [LlamaCppBridge] implements
 * this; [LlamaHandlers] takes the interface so unit tests can substitute a
 * canned-response fake without loading a real GGUF model.
 */
interface LlamaCppBridgeApi {
    fun isLoaded(): Boolean
    fun completePrompt(prompt: String, maxTokens: Int, temperature: Float, topP: Float): String?
    fun embedding(text: String): FloatArray?

    // Phase 2A Pass 1: multimodal projector lifecycle. Pass 1 is stubbed --
    // `loadMmproj` records the path on the native side but doesn't actually
    // initialize an mtmd_context. Pass 2 will swap in real mtmd calls.
    fun loadMmproj(mmprojPath: String): Boolean
    fun unloadMmproj()
    fun isMmprojLoaded(): Boolean
}

/**
 * Kotlin wrapper around the C++ llama.cpp bridge for Android.
 *
 * The pure-Kotlin paths (load/unload state tracking) are exercised by
 * JVM unit tests; JNI calls are exercised by instrumented tests on an
 * Android device or emulator. Each native call is guarded with
 * `try { ... } catch (_: UnsatisfiedLinkError) { ... }` so the JVM tests
 * (which can't load the .so) keep working on the Kotlin-only fallback.
 */
class LlamaCppBridge : LlamaCppBridgeApi {
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
    // Phase 2A Pass 1: track mmproj load state in pure Kotlin so the JVM
    // unit tests can exercise the load/unload state machine even without
    // the .so loaded. The native side has its own `mmproj_path` field;
    // we keep these in sync via the JNI calls below.
    private var mmprojPath: String? = null

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

    override fun isLoaded(): Boolean = isLoadedFlag

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
        // Native unload tears down mtmd_ctx + clears mmproj_path; mirror
        // that on the Kotlin state-machine side too.
        mmprojPath = null
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
    override fun completePrompt(
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

    /**
     * Compute an embedding vector for the given text. Requires the model to
     * have been loaded with `embeddingMode = true`; otherwise the returned
     * values are undefined / not meaningful (the handler layer is responsible
     * for the 400 short-circuit before we get here). Returns the per-dimension
     * floats (length == llama_n_embd(model)) on success, or null if the model
     * isn't loaded / native isn't available (JVM tests).
     */
    override fun embedding(text: String): FloatArray? {
        if (!isLoadedFlag) return null
        if (nativeHandle == 0L) return null // JVM tests: no .so, no embedding.
        return try {
            nativeEmbedding(nativeHandle, text)
        } catch (_: UnsatisfiedLinkError) {
            null
        }
    }

    // -------------------------------------------------------------------
    // Multimodal (mtmd) — Phase 2A Pass 1 stubs
    // -------------------------------------------------------------------
    //
    // Pass 1 only tracks load state; the native side is also a stub and
    // does not yet call `mtmd_init_from_file`. Pass 2 will replace both
    // ends with real mtmd calls. JVM unit tests fall back to the Kotlin-
    // only state machine via the UnsatisfiedLinkError catch.

    /**
     * Load a multimodal projector (mmproj). The main model must already be
     * loaded. Returns true on success. JVM unit tests (no .so loaded) keep
     * working via the UnsatisfiedLinkError fallback -- they update the
     * Kotlin state without touching JNI.
     */
    override fun loadMmproj(mmprojPath: String): Boolean {
        if (mmprojPath.isEmpty()) return false
        // Pass 2: a missing main model is a hard error. Pass 1 enforces it
        // here too, so the public Kotlin contract stays stable across both
        // passes.
        if (!isLoadedFlag) return false
        val ok: Boolean = if (nativeHandle != 0L) {
            try {
                nativeLoadMmproj(nativeHandle, mmprojPath)
            } catch (_: UnsatisfiedLinkError) {
                true // JVM-only test fallback
            }
        } else {
            true // JNI not available; pretend success for state-machine tests
        }
        if (ok) {
            this.mmprojPath = mmprojPath
        }
        return ok
    }

    override fun unloadMmproj() {
        if (nativeHandle != 0L) {
            try { nativeUnloadMmproj(nativeHandle) } catch (_: UnsatisfiedLinkError) { /* ignore */ }
        }
        mmprojPath = null
    }

    override fun isMmprojLoaded(): Boolean = mmprojPath != null

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
    private external fun nativeEmbedding(handle: Long, text: String): FloatArray?
    // Phase 2A Pass 1: mtmd JNI surface. Pass 2 will keep the same
    // signatures and only change the native implementations.
    private external fun nativeLoadMmproj(handle: Long, mmprojPath: String): Boolean
    private external fun nativeUnloadMmproj(handle: Long)
    private external fun nativeIsMmprojLoaded(handle: Long): Boolean
}
