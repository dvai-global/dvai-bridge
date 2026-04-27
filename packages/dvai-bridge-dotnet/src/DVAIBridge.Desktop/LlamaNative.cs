using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace DVAIBridge.Desktop;

/// <summary>
/// P/Invoke declarations for the minimum-viable subset of llama.cpp's C API
/// (release tag <c>b8946</c>). Used by <see cref="LlamaInferenceEngine"/>.
///
/// <para>
/// The native library is named <c>llama</c>; .NET's
/// <see cref="DllImportAttribute"/> name resolution maps that to
/// <c>llama.dll</c> on Windows, <c>libllama.dylib</c> on macOS,
/// <c>libllama.so</c> on Linux. The static constructor below registers a
/// custom resolver via <see cref="NativeLibrary.SetDllImportResolver"/>
/// so the lookup picks up the RID-keyed binary shipped under
/// <c>runtimes/&lt;rid&gt;/native/</c> next to the assembly first, before
/// falling back to the OS-default search paths.
/// </para>
///
/// <para>
/// We pin to the C ABI (CallingConvention.Cdecl). All handle types are
/// opaque <see cref="IntPtr"/>s; we don't try to mirror llama.h's
/// internal struct layouts.
/// </para>
/// </summary>
internal static class LlamaNative
{
    public const string LibraryName = "llama";

    /// <summary>
    /// Static constructor — runs once on first reference to any member of
    /// this type. CA2255 advises against
    /// <c>System.Runtime.CompilerServices.ModuleInitializerAttribute</c>
    /// in libraries (it forces eager init even when no API is touched);
    /// the static-ctor variant is functionally equivalent for our case
    /// since every public method on this class triggers the cctor on
    /// first reference, well before the first <c>[DllImport("llama")]</c>
    /// invocation.
    /// </summary>
    static LlamaNative()
    {
        NativeLibrary.SetDllImportResolver(typeof(LlamaNative).Assembly, Resolve);
    }

    private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (libraryName != LibraryName) return IntPtr.Zero;

        // Compute the expected per-RID path next to the assembly. This is
        // where NuGet places <Content> items packed into runtimes/<rid>/native/
        // when restored under the consumer's RID.
        var asmDir = Path.GetDirectoryName(assembly.Location) ?? ".";

        var candidates = GetCandidateFileNames();
        foreach (var candidate in candidates)
        {
            // 1. RID-relative subfolder from a runtimes/-shaped restore.
            var ridPath = Path.Combine(asmDir, "runtimes", GetRid(), "native", candidate);
            if (File.Exists(ridPath) && NativeLibrary.TryLoad(ridPath, out var h1)) return h1;

            // 2. Bare next-to-assembly (single-file deployments).
            var flatPath = Path.Combine(asmDir, candidate);
            if (File.Exists(flatPath) && NativeLibrary.TryLoad(flatPath, out var h2)) return h2;
        }

        // 3. Fall back to the OS default search path.
        return NativeLibrary.TryLoad(libraryName, assembly, searchPath, out var h3)
            ? h3
            : IntPtr.Zero;
    }

    private static string[] GetCandidateFileNames()
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            return new[] { "llama.dll" };
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
            return new[] { "libllama.dylib", "llama.dylib" };
        return new[] { "libllama.so", "llama.so" };
    }

    private static string GetRid()
    {
        var arch = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.X64 => "x64",
            Architecture.Arm64 => "arm64",
            _ => "x64",
        };
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return $"win-{arch}";
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) return $"osx-{arch}";
        return $"linux-{arch}";
    }

    // --- Backend init/teardown ---

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_backend_init();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_backend_free();

    // --- Model load/free ---

    [StructLayout(LayoutKind.Sequential)]
    public struct LlamaModelParams
    {
        public IntPtr devices;            // ggml_backend_dev_t* (NULL = auto)
        public IntPtr tensor_buft_overrides;
        public int n_gpu_layers;
        public int split_mode;
        public int main_gpu;
        public IntPtr tensor_split;
        public IntPtr progress_callback;
        public IntPtr progress_callback_user_data;
        public IntPtr kv_overrides;
        [MarshalAs(UnmanagedType.I1)] public bool vocab_only;
        [MarshalAs(UnmanagedType.I1)] public bool use_mmap;
        [MarshalAs(UnmanagedType.I1)] public bool use_mlock;
        [MarshalAs(UnmanagedType.I1)] public bool check_tensors;
    }

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern LlamaModelParams llama_model_default_params();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi, BestFitMapping = false, ThrowOnUnmappableChar = true)]
    public static extern IntPtr llama_model_load_from_file(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string pathModel,
        LlamaModelParams parameters);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_model_free(IntPtr model);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_n_vocab(IntPtr model);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_n_ctx_train(IntPtr model);

    // --- Context create/free ---

    [StructLayout(LayoutKind.Sequential)]
    public struct LlamaContextParams
    {
        public uint n_ctx;
        public uint n_batch;
        public uint n_ubatch;
        public uint n_seq_max;
        public int n_threads;
        public int n_threads_batch;
        public int rope_scaling_type;
        public int pooling_type;
        public int attention_type;
        public float rope_freq_base;
        public float rope_freq_scale;
        public float yarn_ext_factor;
        public float yarn_attn_factor;
        public float yarn_beta_fast;
        public float yarn_beta_slow;
        public uint yarn_orig_ctx;
        public float defrag_thold;
        public IntPtr cb_eval;
        public IntPtr cb_eval_user_data;
        public int type_k;
        public int type_v;
        [MarshalAs(UnmanagedType.I1)] public bool logits_all;
        [MarshalAs(UnmanagedType.I1)] public bool embeddings;
        [MarshalAs(UnmanagedType.I1)] public bool offload_kqv;
        [MarshalAs(UnmanagedType.I1)] public bool flash_attn;
        [MarshalAs(UnmanagedType.I1)] public bool no_perf;
        [MarshalAs(UnmanagedType.I1)] public bool op_offload;
        [MarshalAs(UnmanagedType.I1)] public bool swa_full;
    }

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern LlamaContextParams llama_context_default_params();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_init_from_model(IntPtr model, LlamaContextParams parameters);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_free(IntPtr ctx);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern uint llama_n_ctx(IntPtr ctx);

    // --- Tokenize/detokenize ---

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_tokenize(
        IntPtr model,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string text,
        int textLen,
        [Out] int[] tokensOut,
        int nTokensMax,
        [MarshalAs(UnmanagedType.I1)] bool addSpecial,
        [MarshalAs(UnmanagedType.I1)] bool parseSpecial);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_token_to_piece(
        IntPtr model,
        int token,
        [Out] byte[] buf,
        int bufLen,
        int lstrip,
        [MarshalAs(UnmanagedType.I1)] bool special);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_token_eos(IntPtr model);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_token_bos(IntPtr model);

    // --- Decode ---

    [StructLayout(LayoutKind.Sequential)]
    public struct LlamaBatch
    {
        public int n_tokens;
        public IntPtr token;
        public IntPtr embd;
        public IntPtr pos;
        public IntPtr n_seq_id;
        public IntPtr seq_id;
        public IntPtr logits;
    }

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern LlamaBatch llama_batch_get_one(IntPtr tokens, int n_tokens);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_decode(IntPtr ctx, LlamaBatch batch);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_get_logits_ith(IntPtr ctx, int i);

    // --- Sampler chain ---

    [StructLayout(LayoutKind.Sequential)]
    public struct LlamaSamplerChainParams
    {
        [MarshalAs(UnmanagedType.I1)] public bool no_perf;
    }

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern LlamaSamplerChainParams llama_sampler_chain_default_params();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_sampler_chain_init(LlamaSamplerChainParams parameters);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_sampler_chain_add(IntPtr chain, IntPtr sampler);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_sampler_init_top_k(int k);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_sampler_init_top_p(float p, UIntPtr min_keep);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_sampler_init_temp(float t);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_sampler_init_dist(uint seed);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_sampler_sample(IntPtr smpl, IntPtr ctx, int idx);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_sampler_accept(IntPtr smpl, int token);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_sampler_free(IntPtr sampler);
}
