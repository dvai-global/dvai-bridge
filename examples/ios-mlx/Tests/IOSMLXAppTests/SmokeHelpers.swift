// examples/ios-mlx/Tests/IOSMLXAppTests/SmokeHelpers.swift
//
// Shared smoke-test helpers (duplicated per-example for SwiftPM reasons —
// see ios-llama/Tests/.../SmokeHelpers.swift).

import Foundation
import XCTest

enum SmokeEnv {
    static func load() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("SMOKE_") }
        if !env.isEmpty { return env }
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts/smoke.local.env").path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return env }
            dir = parent
        }
        let envFile = dir.appendingPathComponent("scripts/smoke.local.env")
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else { return env }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2 {
                if (value.first == "\"" && value.last == "\"") ||
                   (value.first == "'" && value.last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            if key.hasPrefix("SMOKE_") && !value.isEmpty { env[key] = value }
        }
        return env
    }
}

enum SmokeHttp {
    static func postChatCompletion(baseUrl: String, messages: [[String: String]]) async throws -> String {
        let url = URL(string: "\(baseUrl)/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "messages": messages,
            "max_tokens": 32,
            "temperature": 0.0,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Smoke", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "POST failed: \(String(data: data, encoding: .utf8) ?? "")"
            ])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        return message ?? ""
    }
}
