import XCTest
@testable import DVAICoreMLCore

final class CoreMLTokenizerTests: XCTestCase {
    func testInitFailsForMissingDir() async {
        let bogus = URL(fileURLWithPath: "/tmp/no-such-tokenizer-dir-xyz")
        do {
            _ = try await CoreMLTokenizer(tokenizerDir: bogus)
            XCTFail("Expected throw for missing tokenizer dir")
        } catch let err as CoreMLBackendError {
            guard case .tokenizerLoadFailed = err else {
                return XCTFail("wrong error type: \(err)")
            }
            // Pass — missing dir correctly converts to tokenizerLoadFailed
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
