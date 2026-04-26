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

    // Phase 2A Pass 2: real multimodal projector (mmproj) lifecycle +
    // chat-template + multimodal completion.
    fun loadMmproj(mmprojPath: String): Boolean
    fun unloadMmproj()
    fun isMmprojLoaded(): Boolean
    /** Whether the loaded model declares an audio encoder. False until mmproj loaded. */
    fun hasAudioEncoder(): Boolean

    /**
     * Apply `llama_chat_apply_template`. Empty/null templateOverride falls
     * back to the model's bundled `tokenizer.chat_template`. Returns the
     * rendered prompt string, or null if templating fails.
     */
    fun applyChatTemplate(
        templateOverride: String?,
        messages: List<Map<String, String>>,
        addAssistant: Boolean,
    ): String?

    /**
     * Multimodal completion. The prompt must contain N `<__media__>` markers
     * matching `media.size`; bytes are auto-detected as image vs audio.
     */
    fun completeMultimodalPrompt(
        prompt: String,
        media: List<ByteArray>,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
    ): String?
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
    // Track mmproj load state in pure Kotlin so JVM unit tests can exercise
    // the load/unload state machine even without the .so loaded.
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
            true
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
        mmprojPath = null
    }

    fun versionString(): String {
        if (nativeHandle != 0L) {
            try { return nativeVersionString(nativeHandle) } catch (_: UnsatisfiedLinkError) { /* fall through */ }
        }
        return "llama.cpp-stub-android-0.1"
    }

    override fun completePrompt(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
    ): String? {
        if (!isLoadedFlag) return null
        if (nativeHandle == 0L) return null
        return try {
            nativeCompletePrompt(nativeHandle, prompt, maxTokens, temperature, topP)
        } catch (_: UnsatisfiedLinkError) {
            null
        }
    }

    override fun embedding(text: String): FloatArray? {
        if (!isLoadedFlag) return null
        if (nativeHandle == 0L) return null
        return try {
            nativeEmbedding(nativeHandle, text)
        } catch (_: UnsatisfiedLinkError) {
            null
        }
    }

    // -------------------------------------------------------------------
    // Multimodal (mtmd) — Phase 2A Pass 2
    // -------------------------------------------------------------------

    override fun loadMmproj(mmprojPath: String): Boolean {
        if (mmprojPath.isEmpty()) return false
        if (!isLoadedFlag) return false
        val ok: Boolean = if (nativeHandle != 0L) {
            try {
                nativeLoadMmproj(nativeHandle, mmprojPath)
            } catch (_: UnsatisfiedLinkError) {
                true // JVM-only test fallback
            }
        } else {
            true
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

    override fun isMmprojLoaded(): Boolean {
        // Source of truth is the C++ holder (`h->mtmd_ctx != nullptr`), not the
        // Kotlin-side `mmprojPath` field — that mirrors iOS's `_mtmdCtx != NULL`
        // check and stays correct if `mtmd_init_from_file` ever fails after
        // `mmprojPath` was set. The Kotlin field is still used to nil things
        // out on `unload()`/`unloadMmproj()`, but we don't read it here on
        // the production path.
        return if (nativeHandle != 0L) {
            try {
                nativeIsMmprojLoaded(nativeHandle)
            } catch (_: UnsatisfiedLinkError) {
                // JVM unit-test fallback: no .so loaded, defer to the Kotlin field.
                mmprojPath != null
            }
        } else {
            // No native handle (JVM-only test bridge) — defer to the Kotlin field.
            mmprojPath != null
        }
    }

    override fun hasAudioEncoder(): Boolean {
        if (!isMmprojLoaded()) return false
        if (nativeHandle == 0L) return false
        return try {
            nativeHasAudioEncoder(nativeHandle)
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    override fun applyChatTemplate(
        templateOverride: String?,
        messages: List<Map<String, String>>,
        addAssistant: Boolean,
    ): String? {
        if (!isLoadedFlag) return null
        if (messages.isEmpty()) return null
        val roles = Array(messages.size) { messages[it]["role"] ?: "user" }
        val contents = Array(messages.size) { messages[it]["content"] ?: "" }
        if (nativeHandle == 0L) return null
        return try {
            nativeApplyChatTemplate(nativeHandle, templateOverride, roles, contents, addAssistant)
        } catch (_: UnsatisfiedLinkError) {
            null
        }
    }

    override fun completeMultimodalPrompt(
        prompt: String,
        media: List<ByteArray>,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
    ): String? {
        if (!isLoadedFlag) return null
        if (!isMmprojLoaded()) return null
        if (nativeHandle == 0L) return null
        val mediaArr: Array<ByteArray> = media.toTypedArray()
        return try {
            nativeCompleteMultimodalPrompt(nativeHandle, prompt, mediaArr, maxTokens, temperature, topP)
        } catch (_: UnsatisfiedLinkError) {
            null
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
    private external fun nativeEmbedding(handle: Long, text: String): FloatArray?
    // Phase 2A Pass 2: mtmd JNI surface.
    private external fun nativeLoadMmproj(handle: Long, mmprojPath: String): Boolean
    private external fun nativeUnloadMmproj(handle: Long)
    private external fun nativeIsMmprojLoaded(handle: Long): Boolean
    private external fun nativeHasAudioEncoder(handle: Long): Boolean
    private external fun nativeApplyChatTemplate(
        handle: Long,
        templateOverride: String?,
        roles: Array<String>,
        contents: Array<String>,
        addAssistant: Boolean,
    ): String?
    private external fun nativeCompleteMultimodalPrompt(
        handle: Long,
        prompt: String,
        media: Array<ByteArray>,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
    ): String?
}
