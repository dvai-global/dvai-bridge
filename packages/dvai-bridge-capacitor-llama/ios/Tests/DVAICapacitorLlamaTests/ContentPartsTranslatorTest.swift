import XCTest
@testable import DVAICapacitorLlama

final class ContentPartsTranslatorTest: XCTestCase {
    // MARK: - Mocks

    /// Image decoder that returns canned bytes per URL. Records every call so
    /// tests can assert which URLs were passed in and in what order.
    final class MockImageDecoder: ImageDecoderProtocol {
        var responses: [String: Data] = [:]
        var calls: [String] = []
        func resolve(url: String) async throws -> Data {
            calls.append(url)
            if let bytes = responses[url] { return bytes }
            return Data([0xDE, 0xAD, 0xBE, 0xEF])
        }
    }

    /// Audio-decoder closure factory. Records each call's `(bytesIn, format)`
    /// and returns canned PCM bytes.
    final class AudioRecorder {
        var calls: [(Data, AudioFormat)] = []
        var pcmOut: Data = Data([0x11, 0x22, 0x33, 0x44])
        func make() -> (Data, AudioFormat) async throws -> Data {
            { [unowned self] data, format in
                self.calls.append((data, format))
                return self.pcmOut
            }
        }
    }

    // MARK: - Fixture loader

    /// Loads `transport-fixtures.json` from the repo-root `fixtures/` dir.
    /// For `CHAT_REQUEST_AUDIO_PCM16` the `data` field carries the literal
    /// `"<replaced-by-loader>"` placeholder; we substitute the base64 of the
    /// PCM16 fixture file before returning.
    private func loadFixture(_ key: String) throws -> [String: Any] {
        let url = fixturesURL().appendingPathComponent("transport-fixtures.json")
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var fixture = root[key] as? [String: Any] else {
            XCTFail("fixture \(key) missing or not an object")
            return [:]
        }
        if key == "CHAT_REQUEST_AUDIO_PCM16" {
            let pcmURL = fixturesURL().appendingPathComponent("audio").appendingPathComponent("pcm16-1s-16khz-mono.bin")
            let pcmBytes = try Data(contentsOf: pcmURL)
            let b64 = pcmBytes.base64EncodedString()
            // Mutate messages[0].content[0].input_audio.data
            if var messages = fixture["messages"] as? [[String: Any]],
               var msg0 = messages.first,
               var parts = msg0["content"] as? [[String: Any]],
               var part0 = parts.first,
               var audio = part0["input_audio"] as? [String: Any] {
                audio["data"] = b64
                part0["input_audio"] = audio
                parts[0] = part0
                msg0["content"] = parts
                messages[0] = msg0
                fixture["messages"] = messages
                root[key] = fixture
            } else {
                XCTFail("CHAT_REQUEST_AUDIO_PCM16 fixture shape unexpected")
            }
        }
        return fixture
    }

    private func messages(from fixture: [String: Any]) -> [[String: Any]] {
        (fixture["messages"] as? [[String: Any]]) ?? []
    }

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

    // MARK: - Happy paths (driven by transport-fixtures.json)

    /// `CHAT_REQUEST_TEXT` — the legacy string-content shape produces a prompt
    /// with the user text and no media collateral.
    func testTextOnlyMessage() async throws {
        let fixture = try loadFixture("CHAT_REQUEST_TEXT")
        let translator = ContentPartsTranslator(mmprojLoaded: false, modelHasAudioEncoder: false)
        let result = try await translator.translate(messages: messages(from: fixture))
        XCTAssertEqual(result.prompt, "hi")
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertTrue(result.audioPCM.isEmpty)
    }

    /// `CHAT_REQUEST_IMAGE` — text + data-URL image. The image part should be
    /// resolved via the (mocked) ImageDecoder and the bytes appended to
    /// `images`. The text part populates `prompt`.
    func testTextPlusImage() async throws {
        let fixture = try loadFixture("CHAT_REQUEST_IMAGE")
        let mock = MockImageDecoder()
        let cannedPng = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x99])
        // Prefix-match any data: URL by snapping it after we observe it; here
        // we just set a default in `responses` keyed off the actual URL once
        // we know it from the fixture.
        let urlFromFixture: String = {
            let parts = (((fixture["messages"] as? [[String: Any]])?[0])?["content"] as? [[String: Any]]) ?? []
            return ((parts.first(where: { ($0["type"] as? String) == "image_url" })?["image_url"] as? [String: Any])?["url"] as? String) ?? ""
        }()
        mock.responses[urlFromFixture] = cannedPng

        let translator = ContentPartsTranslator(
            mmprojLoaded: true,
            modelHasAudioEncoder: false,
            imageDecoder: mock
        )
        let result = try await translator.translate(messages: messages(from: fixture))
        XCTAssertEqual(result.prompt, "What is in this image?")
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.images[0], cannedPng)
        XCTAssertEqual(mock.calls, [urlFromFixture])
        XCTAssertTrue(result.audioPCM.isEmpty)
    }

    /// `CHAT_REQUEST_AUDIO_PCM16` — base64-encoded PCM16 + text. The base64
    /// payload is fed (decoded) into the audio-decoder closure with
    /// `format == .pcm16`; the canned PCM result lands in `audioPCM`.
    func testAudioPCM16PlusText() async throws {
        let fixture = try loadFixture("CHAT_REQUEST_AUDIO_PCM16")
        let recorder = AudioRecorder()
        let translator = ContentPartsTranslator(
            mmprojLoaded: false,
            modelHasAudioEncoder: true,
            audioDecoder: recorder.make()
        )
        let result = try await translator.translate(messages: messages(from: fixture))
        XCTAssertEqual(result.prompt, "Transcribe this.")
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertEqual(result.audioPCM.count, 1)
        XCTAssertEqual(result.audioPCM[0], recorder.pcmOut)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls[0].1, .pcm16)
        // The recorder receives the raw decoded PCM bytes (the fixture loader
        // base64-encodes the PCM file, the translator base64-decodes it back).
        let pcmFile = try Data(contentsOf: fixturesURL().appendingPathComponent("audio").appendingPathComponent("pcm16-1s-16khz-mono.bin"))
        XCTAssertEqual(recorder.calls[0].0, pcmFile)
    }

    // MARK: - Negative paths

    /// Image part with `mmprojLoaded == false` → `noMmprojForImage`. The
    /// translator must throw before even consulting the image decoder.
    func testImageWithoutMmprojThrows() async {
        let messages: [[String: Any]] = [[
            "role": "user",
            "content": [
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]
            ],
        ]]
        let mock = MockImageDecoder()
        let translator = ContentPartsTranslator(
            mmprojLoaded: false,
            modelHasAudioEncoder: false,
            imageDecoder: mock
        )
        do {
            _ = try await translator.translate(messages: messages)
            XCTFail("expected noMmprojForImage")
        } catch TranslatorError.noMmprojForImage {
            XCTAssertTrue(mock.calls.isEmpty, "translator should not invoke decoder when mmproj is missing")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Audio part with `modelHasAudioEncoder == false` → `audioWithoutAudioEncoder`.
    func testAudioWithoutEncoderThrows() async {
        let messages: [[String: Any]] = [[
            "role": "user",
            "content": [
                ["type": "input_audio", "input_audio": ["data": "AAAA", "format": "pcm16"]]
            ],
        ]]
        let translator = ContentPartsTranslator(mmprojLoaded: false, modelHasAudioEncoder: false)
        do {
            _ = try await translator.translate(messages: messages)
            XCTFail("expected audioWithoutAudioEncoder")
        } catch TranslatorError.audioWithoutAudioEncoder {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Unsupported audio format (e.g. `vorbis`) → `unsupportedAudioFormat`
    /// with the offending format echoed back and the supported list filled in.
    func testUnsupportedAudioFormatThrows() async {
        let messages: [[String: Any]] = [[
            "role": "user",
            "content": [
                ["type": "input_audio", "input_audio": ["data": "AAAA", "format": "vorbis"]]
            ],
        ]]
        let translator = ContentPartsTranslator(mmprojLoaded: false, modelHasAudioEncoder: true)
        do {
            _ = try await translator.translate(messages: messages)
            XCTFail("expected unsupportedAudioFormat")
        } catch let TranslatorError.unsupportedAudioFormat(fmt, supported) {
            XCTAssertEqual(fmt, "vorbis")
            XCTAssertEqual(supported, ContentPartsTranslator.supportedAudioFormats)
            XCTAssertTrue(supported.contains("flac"), "iOS supported list should include flac")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Unknown content part type → `malformedRequest` with the offending type
    /// echoed in the message.
    func testUnknownContentPartTypeThrows() async {
        let messages: [[String: Any]] = [[
            "role": "user",
            "content": [
                ["type": "video_url", "video_url": ["url": "https://example.com/v.mp4"]]
            ],
        ]]
        let translator = ContentPartsTranslator(mmprojLoaded: true, modelHasAudioEncoder: true)
        do {
            _ = try await translator.translate(messages: messages)
            XCTFail("expected malformedRequest")
        } catch let TranslatorError.malformedRequest(reason) {
            XCTAssertTrue(reason.contains("video_url"), "expected reason to mention offending type, got: \(reason)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Empty `input_audio.data` → `malformedRequest`. The audio decoder must
    /// not be invoked — this is a request-shape error caught before decode.
    func testEmptyAudioDataThrowsMalformedRequest() async {
        let translator = ContentPartsTranslator(
            mmprojLoaded: false,
            modelHasAudioEncoder: true,
            imageDecoder: MockImageDecoder(),
            audioDecoder: { _, _ in
                XCTFail("audio decoder should not be invoked for empty data")
                return Data()
            }
        )
        let messages: [[String: Any]] = [[
            "role": "user",
            "content": [[
                "type": "input_audio",
                "input_audio": ["data": "", "format": "pcm16"]
            ]]
        ]]
        do {
            _ = try await translator.translate(messages: messages)
            XCTFail("Expected throw")
        } catch TranslatorError.malformedRequest {
            // OK
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    /// Malformed base64 in `input_audio.data` → `malformedRequest` (not
    /// `audioDecodeFailed`). The audio decoder never runs — this is a
    /// pre-decode request-shape error.
    func testMalformedBase64ThrowsMalformedRequest() async {
        let translator = ContentPartsTranslator(
            mmprojLoaded: false,
            modelHasAudioEncoder: true,
            imageDecoder: MockImageDecoder(),
            audioDecoder: { _, _ in
                XCTFail("audio decoder should not be invoked for invalid base64")
                return Data()
            }
        )
        let messages: [[String: Any]] = [[
            "role": "user",
            "content": [[
                "type": "input_audio",
                "input_audio": ["data": "!!!not-valid-base64!!!", "format": "pcm16"]
            ]]
        ]]
        do {
            _ = try await translator.translate(messages: messages)
            XCTFail("Expected throw")
        } catch TranslatorError.malformedRequest {
            // OK
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }
}
