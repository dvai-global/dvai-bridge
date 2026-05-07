// examples/ios-coreml/Sources/IOSCoreMLApp/IOSCoreMLApp.swift
//
// SwiftUI app demonstrating dvai-bridge with the CoreML backend.
//
// The .coreml backend is shipped as experimental in v2.4 — see
// docs/guide/ios-native-sdk.md#known-issues. This example demonstrates
// the integration shape (model load + HTTP server boot + OpenAI client
// pointed at the local endpoint). The actual chat completion may not
// return until the IRValue-format follow-up lands.
//
// Reference checkpoint: finnvoorhees/coreml-Llama-3.2-1B-Instruct-4bit.
// The canonical CoreML Llama-3.2 mlpackage published on the HF Hub.

import SwiftUI
import DVAIBridge
import OpenAI

@main
struct IOSCoreMLApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var state = DVAIBridge.shared.reactive
    @State private var output: String = ""
    @State private var status: String = "Idle"
    @State private var isRunning = false

    /// HF resolve URL prefix for the canonical reference checkpoint.
    /// The .mlmodelc directory + tokenizer.json files are under this URL.
    private static let hfRepoBase = URL(string:
        "https://huggingface.co/finnvoorhees/coreml-Llama-3.2-1B-Instruct-4bit/resolve/main/"
    )!

    var body: some View {
        VStack(spacing: 16) {
            Text("dvai-bridge · iOS · CoreML / ANE")
                .font(.title2).bold()
            Text(status)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            ScrollView {
                Text(output.isEmpty ? "Tap 'Load + Ask' to begin." : output)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
            }
            Button(action: { Task { await loadAndAsk() } }) {
                Text(isRunning ? "Working…" : "Load + Ask")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isRunning ? Color.gray : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .disabled(isRunning)
            Text("Experimental — see README for known issues.")
                .font(.caption2)
                .foregroundColor(.orange)
        }
        .padding()
    }

    private func loadAndAsk() async {
        if #available(iOS 18.0, macOS 15.0, *) {
            // ok
        } else {
            status = "CoreML backend requires iOS 18+ / macOS 15+."
            return
        }
        isRunning = true
        defer { isRunning = false }
        output = ""
        do {
            // 1. Discover the .mlmodelc directory name from the HF API
            //    and download the model file-by-file into a caches dir.
            status = "Downloading CoreML model…"
            let bundle = try await CoreMLModelDownloader.downloadReferenceCheckpoint(
                repoBase: Self.hfRepoBase,
                progress: { msg in
                    Task { @MainActor in self.status = msg }
                }
            )

            // 2. Boot the bridge with backend: .coreml + modelPath +
            //    tokenizerPath. modelPath is the .mlmodelc directory;
            //    tokenizerPath is a directory containing tokenizer.json.
            status = "Loading CoreML model…"
            let server = try await DVAIBridge.shared.start(.init(
                backend: .coreml,
                modelPath: bundle.modelDir.path,
                tokenizerPath: bundle.tokenizerDir.path
            ))

            status = "Streaming…"
            let url = URL(string: server.baseUrl)!
            let host = url.host ?? "127.0.0.1"
            let port = url.port ?? 38883
            let openAI = OpenAI(configuration: .init(
                token: "sk-local",
                host: host,
                port: port,
                scheme: "http",
                basePath: "/v1"
            ))

            for try await chunk in openAI.chatsStream(query: .init(
                messages: [.user(.init(content: .string("Tell me a one-line joke.")))],
                model: "local",
                maxCompletionTokens: 64,
                temperature: 0
            )) {
                if let delta = chunk.choices.first?.delta.content {
                    output += delta
                }
            }
            status = "Done. Backend: \(state.currentBackend?.rawValue ?? "?") · port \(server.port)"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }
}

/// Minimal HF-Hub-aware downloader for stateful CoreML mlpackage
/// directories. Mirrors the SDK's RealModelIntegrationTest helper but
/// scoped to the example's needs.
enum CoreMLModelDownloader {
    struct Bundle {
        let modelDir: URL
        let tokenizerDir: URL
    }

    /// Files inside a stateful CoreML Llama-style `.mlmodelc/` directory.
    /// Stable across the public Apple-style stateful Llama checkpoints
    /// we know about.
    private static let mlmodelcFiles: [String] = [
        "analytics/coremldata.bin",
        "coremldata.bin",
        "metadata.json",
        "model.mil",
        "weights/weight.bin",
    ]

    static func downloadReferenceCheckpoint(
        repoBase: URL,
        progress: @escaping (String) -> Void
    ) async throws -> Bundle {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("dvai-coreml-example", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let dirName = try await discoverMlmodelcDirName(repoUrl: repoBase)
        let modelDir = cacheRoot.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(
            at: modelDir.appendingPathComponent("analytics"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDir.appendingPathComponent("weights"),
            withIntermediateDirectories: true
        )
        var i = 1
        for rel in mlmodelcFiles {
            progress("Downloading \(rel) (\(i)/\(mlmodelcFiles.count))")
            let src = repoBase.appendingPathComponent("\(dirName)/\(rel)")
            let dest = modelDir.appendingPathComponent(rel)
            try await downloadOne(src: src, dest: dest)
            i += 1
        }

        let tokenizerDir = cacheRoot.appendingPathComponent("tokenizer")
        try? FileManager.default.createDirectory(at: tokenizerDir, withIntermediateDirectories: true)
        progress("Downloading tokenizer…")
        try await downloadOne(
            src: repoBase.appendingPathComponent("tokenizer.json"),
            dest: tokenizerDir.appendingPathComponent("tokenizer.json")
        )
        try? await downloadOneOptional(
            src: repoBase.appendingPathComponent("tokenizer_config.json"),
            dest: tokenizerDir.appendingPathComponent("tokenizer_config.json")
        )

        return Bundle(modelDir: modelDir, tokenizerDir: tokenizerDir)
    }

    private static func discoverMlmodelcDirName(repoUrl: URL) async throws -> String {
        // /<owner>/<repo>/resolve/<rev>/...
        let comps = repoUrl.pathComponents
        guard let resolveIdx = comps.firstIndex(of: "resolve"), resolveIdx >= 2 else {
            throw NSError(domain: "Example", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "repo URL must look like .../<owner>/<repo>/resolve/<rev>/"
            ])
        }
        let owner = comps[resolveIdx - 2]
        let repo = comps[resolveIdx - 1]
        let api = URL(string: "https://huggingface.co/api/models/\(owner)/\(repo)")!
        let (data, _) = try await URLSession.shared.data(from: api)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]] else {
            throw NSError(domain: "Example", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "could not parse HF siblings list"
            ])
        }
        for s in siblings {
            if let path = s["rfilename"] as? String,
               let r = path.range(of: ".mlmodelc/") {
                return String(path[..<r.upperBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        throw NSError(domain: "Example", code: -3, userInfo: [
            NSLocalizedDescriptionKey: "no *.mlmodelc/ entry in repo"
        ])
    }

    private static func downloadOne(src: URL, dest: URL) async throws {
        let (tmp, resp) = try await URLSession.shared.download(from: src)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Example", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(src.lastPathComponent)"
            ])
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    private static func downloadOneOptional(src: URL, dest: URL) async throws {
        do { try await downloadOne(src: src, dest: dest) } catch { /* ignore */ }
    }
}
