import XCTest
import CoreML
@testable import DVAICoreMLCore

final class CoreMLSamplerTests: XCTestCase {
    func makeLogits(_ vals: [Float]) -> MLMultiArray {
        let arr = try! MLMultiArray(shape: [NSNumber(value: vals.count)], dataType: .float32)
        for (i, v) in vals.enumerated() { arr[i] = NSNumber(value: v) }
        return arr
    }

    func testGreedyReturnsArgmax() {
        let s = CoreMLSampler(temperature: 0, topP: 1.0, topK: 0)
        let logits = makeLogits([1.0, 5.0, 2.0, 4.0])
        XCTAssertEqual(s.sample(logits: logits), 1)  // argmax index
    }

    func testTemperatureSamplingNeverThrows() {
        let s = CoreMLSampler(temperature: 1.0, topP: 1.0, topK: 0)
        let logits = makeLogits([1.0, 2.0, 3.0, 4.0])
        for _ in 0 ..< 100 {
            let token = s.sample(logits: logits)
            XCTAssertGreaterThanOrEqual(token, 0)
            XCTAssertLessThan(token, 4)
        }
    }

    func testTopPTruncationFavorsHighProb() {
        // With top_p = 0.5 and a sharply skewed distribution, only the top
        // few tokens should ever be selected.
        let s = CoreMLSampler(temperature: 1.0, topP: 0.5, topK: 0)
        // Logits chosen so that softmax(logits) ≈ [0.0, 0.0, 0.05, 0.95]
        let logits = makeLogits([-100.0, -100.0, 1.0, 4.0])
        var counts = [0, 0, 0, 0]
        for _ in 0 ..< 1000 { counts[s.sample(logits: logits)] += 1 }
        XCTAssertEqual(counts[0], 0)
        XCTAssertEqual(counts[1], 0)
        XCTAssertGreaterThan(counts[3], counts[2])  // 4.0 picked far more often than 1.0
    }
}
