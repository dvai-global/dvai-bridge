import XCTest
@testable import DVAILlamaCore

final class AudioDecoderTest: XCTestCase {
    func testPCM16PassThrough() async throws {
        let pcm = try Data(contentsOf: audioFixtureURL("pcm16-1s-16khz-mono.bin"))
        let result = try await AudioDecoder.decode(data: pcm, format: .pcm16)
        XCTAssertEqual(result.count, pcm.count)
    }

    func testWavToPCM() async throws {
        let wav = try Data(contentsOf: audioFixtureURL("wav-1s-16khz-mono.wav"))
        let result = try await AudioDecoder.decode(data: wav, format: .wav)
        // 1s @ 16kHz mono PCM16 = 32000 bytes (allow ±5%).
        XCTAssertGreaterThan(result.count, 30000)
        XCTAssertLessThan(result.count, 34000)
    }

    func testM4AToPCM() async throws {
        let m4a = try Data(contentsOf: audioFixtureURL("m4a-1s.m4a"))
        let result = try await AudioDecoder.decode(data: m4a, format: .m4a)
        // M4A AAC 1s decodes to ~32000 bytes; AAC priming may shave a few hundred samples.
        XCTAssertGreaterThan(result.count, 25000)
        XCTAssertLessThan(result.count, 36000)
    }

    /// Walks up from this test source file until it finds the repo-root
    /// `fixtures/` directory. We don't bundle the fixtures into the SwiftPM
    /// test target's resources because they're shared with Android and Node
    /// tests.
    private func fixturesURL() -> URL {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("fixtures").path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path {
                fatalError("fixtures dir not found walking up from \(#file)")
            }
            dir = parent
        }
        return dir.appendingPathComponent("fixtures")
    }

    private func audioFixtureURL(_ name: String) -> URL {
        fixturesURL().appendingPathComponent("audio").appendingPathComponent(name)
    }
}
