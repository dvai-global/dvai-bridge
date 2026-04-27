import Foundation

internal enum BackendSelector {
    /// Resolve `.auto` to a concrete backend; pass-through for explicit choices.
    /// - Throws `DVAIBridgeError.configurationInvalid` if `.auto` can't decide.
    static func resolve(_ kind: BackendKind, config: DVAIBridgeConfig) throws -> BackendKind {
        if kind != .auto { return kind }

        // 1. modelPath ending in .gguf → .llama
        if let path = config.modelPath, path.hasSuffix(".gguf") {
            return .llama
        }

        // 2. modelPath ending in .mlmodelc / .mlpackage → .coreml
        if let path = config.modelPath,
           path.hasSuffix(".mlmodelc") || path.hasSuffix(".mlpackage") {
            return .coreml
        }

        // 3. modelPath ending in .task / .litertlm → no iOS backend supports
        //    those; fall through to error
        if let path = config.modelPath,
           path.hasSuffix(".task") || path.hasSuffix(".litertlm") {
            throw DVAIBridgeError.configurationInvalid(reason:
                "Model file '\(path)' is a MediaPipe / LiteRT-LM format. " +
                "Use it via the Android SDK; iOS supports llama.cpp (.gguf), " +
                "Apple Foundation Models (no file), and CoreML (.mlmodelc / .mlpackage).")
        }

        // 4. No modelPath + iOS 26+ → .foundation
        if config.modelPath == nil {
            if #available(iOS 26.0, macOS 26.0, *) {
                return .foundation
            }
            throw DVAIBridgeError.configurationInvalid(reason:
                "auto backend requires either modelPath (for .llama / .coreml) " +
                "or iOS 26+ (for .foundation). Set DVAIBridgeConfig.backend explicitly.")
        }

        // 5. modelPath looks like a HuggingFace id ("<owner>/<repo>" with no
        //    file extension) → likely MLX. Don't auto-resolve here because
        //    not every HF id is MLX (could be GGUF in a HF repo etc.) and
        //    .mlx requires Apple Silicon at runtime. Provide a clear hint.
        if let path = config.modelPath,
           path.contains("/"),
           !path.contains(".") {
            throw DVAIBridgeError.configurationInvalid(reason:
                "modelPath '\(path)' looks like a HuggingFace identifier. " +
                "If this is an MLX-converted checkpoint (e.g. 'mlx-community/...'), " +
                "set DVAIBridgeConfig.backend = .mlx explicitly — `.auto` won't " +
                "infer MLX because not every HF id is an MLX checkpoint.")
        }

        // 6. Unknown extension
        throw DVAIBridgeError.configurationInvalid(reason:
            "auto backend can't infer from modelPath '\(config.modelPath ?? "<nil>")'. " +
            "Set DVAIBridgeConfig.backend = .llama / .foundation / .coreml / .mlx explicitly.")
    }
}
