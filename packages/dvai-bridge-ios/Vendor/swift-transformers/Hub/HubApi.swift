// Vendored, *stripped* version of huggingface/swift-transformers @ 1.3.0
// Sources/Hub/HubApi.swift.
//
// The upstream file is 1444 lines and pulls in Crypto / HuggingFace /
// FoundationNetworking / Network / EventSource / yyjson / swift-xet to
// implement HuggingFace Hub downloads with SHA-256 verification, redirect
// handling, and gated-repo auth. None of those transitive dependencies
// publishes a CocoaPods spec, so vendoring the full upstream file
// transitively requires forking the entire HF Swift stack.
//
// Our DVAICoreMLCore consumer only ever calls `AutoTokenizer.from(modelFolder:)`
// which takes a *local* directory and never executes Hub's network paths.
// The narrow surface our vendored Hub.swift actually exercises on HubApi:
//
//   1. `func configuration(fileURL: URL) throws -> Config`
//   2. `func snapshot(from:revision:matching:) async throws -> URL`
//      (only on the unused modelName-init branch — stubbed to throw)
//
// This file provides exactly that. JSON parsing is performed via
// Foundation's `JSONSerialization` rather than yyjson — the parsed
// `[String: Any]` is fed straight into `Config`'s dictionary initializer,
// which is identical to what HubApi.whoami() already does upstream.
//
// SwiftPM consumers continue to resolve the real upstream HubApi via
// Package.swift; only CocoaPods consumers see this stripped variant.

import Foundation

public final class HubApi: Sendable {
    public static let shared = HubApi()

    public init() {}

    /// Loads a HuggingFace `config.json`-style file from disk and parses it
    /// into a `Config`.
    ///
    /// Upstream uses yyjson via `YYJSONParser.parseToConfig(data)`. We use
    /// `JSONSerialization` from Foundation, which produces the same
    /// `[String: Any]` shape that `Config(_:)` accepts. The cast targets
    /// `[NSString: Any]` to match `Config`'s declared init parameter type.
    public func configuration(fileURL: URL) throws -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw Hub.HubClientError.fileSystemError(error)
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw Hub.HubClientError.jsonSerialization(
                fileURL: fileURL,
                message: "JSON parsing failed for \(fileURL.lastPathComponent): \(error.localizedDescription)"
            )
        }

        guard let dict = parsed as? [NSString: Any] else {
            throw Hub.HubClientError.parseError(
                "JSON root in \(fileURL.lastPathComponent) is not an object"
            )
        }
        return Config(dict)
    }

    /// Stub for the upstream remote-snapshot download. Not supported in
    /// the CocoaPods-vendored build — call sites that hit this path are on
    /// the `LanguageModelConfigurationFromHub(modelName:)` initializer,
    /// which DVAICoreMLCore never uses (we only load tokenizers from a
    /// local `modelFolder`). SwiftPM consumers retain the real
    /// implementation through the upstream package.
    public func snapshot(
        from repo: Hub.Repo,
        revision: String = "main",
        matching files: [String] = []
    ) async throws -> URL {
        throw Hub.HubClientError.downloadError(
            "HubApi.snapshot is not available in the CocoaPods-vendored build of dvai-bridge. " +
                "Use AutoTokenizer.from(modelFolder:) with a local directory; download tokenizer " +
                "files via your own networking (DVAILlamaCore.ModelDownloader works well)."
        )
    }
}
