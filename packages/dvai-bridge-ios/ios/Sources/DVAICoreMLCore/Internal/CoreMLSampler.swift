import Foundation
import CoreML

/// Sampling strategies for autoregressive decoding.
///
/// Note on `seed:` — `SystemRandomNumberGenerator` cannot be seeded; for
/// reproducible sampling a custom PRNG (e.g. Mulberry32) would be needed.
/// Per the plan, we drop `seed:` from the public-facing init entirely rather
/// than silently ignoring it. Apple-managed entropy is fine for production LLM
/// sampling.
internal struct CoreMLSampler {
    let temperature: Float
    let topP: Float
    let topK: Int   // 0 = disabled

    /// Sample a token id from a logits vector.
    /// - Parameter logits: 1-D MLMultiArray<Float32> of length vocab_size.
    func sample(logits: MLMultiArray) -> Int {
        let count = logits.count
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(logits.dataPointer))

        // 1. Greedy fast-path
        if temperature <= 0 {
            return argmax(ptr, count: count)
        }

        // 2. Apply temperature
        var scaled = [Float](repeating: 0, count: count)
        for i in 0 ..< count { scaled[i] = ptr[i] / temperature }

        // 3. Optional top-K filter
        if topK > 0 && topK < count {
            applyTopK(&scaled, k: topK)
        }

        // 4. Softmax → probabilities
        let probs = softmax(scaled)

        // 5. Optional nucleus (top-p) filter
        let final = topP < 1.0 ? applyTopP(probs, p: topP) : probs

        // 6. Categorical draw
        return categoricalSample(final)
    }

    // MARK: - Helpers

    private func argmax(_ ptr: UnsafeMutablePointer<Float32>, count: Int) -> Int {
        var bestIdx = 0
        var bestVal = ptr[0]
        for i in 1 ..< count {
            if ptr[i] > bestVal { bestVal = ptr[i]; bestIdx = i }
        }
        return bestIdx
    }

    private func softmax(_ logits: [Float]) -> [Float] {
        let maxVal = logits.max() ?? 0
        var exps = logits.map { Float(exp(Double($0 - maxVal))) }
        let sum = exps.reduce(0, +)
        if sum > 0 { for i in 0 ..< exps.count { exps[i] /= sum } }
        return exps
    }

    private func applyTopK(_ logits: inout [Float], k: Int) {
        let kth = logits.sorted(by: >).prefix(k).last ?? -.greatestFiniteMagnitude
        for i in 0 ..< logits.count where logits[i] < kth { logits[i] = -.greatestFiniteMagnitude }
    }

    private func applyTopP(_ probs: [Float], p: Float) -> [Float] {
        let sorted = probs.enumerated().sorted { $0.element > $1.element }
        var cum: Float = 0
        var keep = Set<Int>()
        for (idx, prob) in sorted {
            keep.insert(idx)
            cum += prob
            if cum >= p { break }
        }
        var result = probs
        for i in 0 ..< result.count where !keep.contains(i) { result[i] = 0 }
        let sum = result.reduce(0, +)
        if sum > 0 { for i in 0 ..< result.count { result[i] /= sum } }
        return result
    }

    private func categoricalSample(_ probs: [Float]) -> Int {
        var rng = SystemRandomNumberGenerator()
        let r = Float.random(in: 0 ..< 1, using: &rng)
        var cum: Float = 0
        for i in 0 ..< probs.count {
            cum += probs[i]
            if r < cum { return i }
        }
        return probs.count - 1
    }
}
