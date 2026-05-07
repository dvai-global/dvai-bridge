// examples/ios-foundation/Tests/IOSFoundationAppTests/SmokeTests.swift
//
// Smoke test for the ios-foundation example. Gated to iOS 26+/macOS 26+
// at runtime — older simulators get an XCTSkip.

import XCTest
import DVAIBridge

final class SmokeTests: XCTestCase {

    override func tearDown() async throws {
        try? await DVAIBridge.shared.stop()
    }

    func testFoundationSmoke() async throws {
        if #available(iOS 26.0, macOS 26.0, *) {
            // ok — proceed
        } else {
            throw XCTSkip("Foundation Models requires iOS 26+ / macOS 26+ at runtime")
        }

        let server = try await DVAIBridge.shared.start(.init(backend: .foundation))
        XCTAssertEqual(server.backend, .foundation)

        let response = try await SmokeHttp.postChatCompletion(
            baseUrl: server.baseUrl,
            messages: [["role": "user", "content": "Hello"]]
        )
        XCTAssertFalse(response.isEmpty, "foundation completion should not be empty")
    }
}
