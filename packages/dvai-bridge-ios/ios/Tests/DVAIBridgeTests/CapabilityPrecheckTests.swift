import XCTest
@testable import DVAIBridge

/// v3.2 — pre-init capability gate (Swift parallel to Android's
/// CapabilityPrecheckTest.kt and TS precheck.test.ts). Same hint
/// shapes, same expected modes — guarantees that iOS, Android, and
/// the TS core agree on what's a "too-weak" or "offload-only" device
/// for any given hardware profile.
@available(iOS 14.0, macOS 11.0, *)
final class CapabilityPrecheckTests: XCTestCase {

    private let highEndDesktop = DeviceCapabilityHints(
        hasNpu: false, ramGb: 32, gpuClass: .discrete, cpuClass: .high
    )
    private let appleSiliconLaptop = DeviceCapabilityHints(
        hasNpu: true, ramGb: 16, gpuClass: .appleSilicon, cpuClass: .high
    )
    private let midRangeLaptop = DeviceCapabilityHints(
        hasNpu: false, ramGb: 8, gpuClass: .integrated, cpuClass: .mid
    )
    private let lowEndLaptop = DeviceCapabilityHints(
        hasNpu: false, ramGb: 4, gpuClass: .integrated, cpuClass: .low
    )
    private let veryWeakDevice = DeviceCapabilityHints(
        hasNpu: false, ramGb: 2, gpuClass: .none, cpuClass: .low
    )

    func testHighEndDesktopClassifiesAsOk() {
        let result = CapabilityPrecheck.assess(hints: highEndDesktop)
        XCTAssertEqual(result.mode, .ok)
        XCTAssertGreaterThan(result.tokPerSec, 10.0)
    }

    func testAppleSiliconClassifiesAsOk() {
        let result = CapabilityPrecheck.assess(hints: appleSiliconLaptop)
        XCTAssertEqual(result.mode, .ok)
    }

    func testMidRangeLaptopClassifiesAsOffloadOnly() {
        // 8 (integrated) * 1.0 (mid CPU) * 1.0 (8 GB RAM) * 1.0 (no NPU) = 8 tok/s
        // Above hardwareMinimum (3), below minLocalCapability (10) → offload-only.
        let result = CapabilityPrecheck.assess(hints: midRangeLaptop)
        XCTAssertEqual(result.mode, .offloadOnly)
        XCTAssertEqual(result.tokPerSec, 8.0, accuracy: 0.01)
    }

    func testLowEndLaptopClassifiesAsOffloadOnly() {
        // 8 * 0.6 * 0.7 = 3.4 tok/s → above floor (3), below comfort (10).
        let result = CapabilityPrecheck.assess(hints: lowEndLaptop)
        XCTAssertEqual(result.mode, .offloadOnly)
    }

    func testVeryWeakDeviceClassifiesAsTooWeak() {
        // 3 (no GPU) * 0.6 (low CPU) * 0.3 (RAM < 4) = 0.5 tok/s → too-weak.
        let result = CapabilityPrecheck.assess(hints: veryWeakDevice)
        XCTAssertEqual(result.mode, .tooWeak)
        XCTAssertLessThan(result.tokPerSec, 3.0)
    }

    func testCustomHardwareMinimumIsHonored() {
        // Mid-range gets 8 tok/s. Raise the floor above that → too-weak.
        let result = CapabilityPrecheck.assess(
            thresholds: CapabilityPrecheck.Thresholds(hardwareMinimum: 12.0),
            hints: midRangeLaptop
        )
        XCTAssertEqual(result.mode, .tooWeak)
    }

    func testCustomMinLocalCapabilityIsHonored() {
        // Mid-range gets 8 tok/s. Lower the comfort threshold to 5 → ok.
        let result = CapabilityPrecheck.assess(
            thresholds: CapabilityPrecheck.Thresholds(minLocalCapability: 5.0),
            hints: midRangeLaptop
        )
        XCTAssertEqual(result.mode, .ok)
    }

    func testReasonContainsTokPerSec() {
        let result = CapabilityPrecheck.assess(hints: veryWeakDevice)
        XCTAssertTrue(
            result.reason.contains("tok/s"),
            "reason should mention tok/s — got: \(result.reason)"
        )
    }

    func testHardwareAssessmentIsCodableRoundTrip() throws {
        let result = CapabilityPrecheck.assess(hints: veryWeakDevice)
        let assessment = HardwareAssessment(from: result)
        let encoded = try JSONEncoder().encode(assessment)
        let decoded = try JSONDecoder().decode(HardwareAssessment.self, from: encoded)
        XCTAssertEqual(decoded.mode, .tooWeak)
        XCTAssertLessThan(decoded.tokPerSec, 3.0)
        XCTAssertEqual(decoded.hints, veryWeakDevice)
    }

    /// Wire-format strings should be stable across SDK versions for
    /// cross-platform parity; rendering a JSON with this exact shape
    /// is the contract every other SDK reads / writes.
    func testWireFormatMatchesCrossPlatform() throws {
        let result = CapabilityPrecheck.assess(hints: midRangeLaptop)
        let assessment = HardwareAssessment(from: result)
        let encoded = try JSONEncoder().encode(assessment)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains("\"offload-only\""), "expected kebab-case mode in JSON: \(json)")
        XCTAssertTrue(json.contains("\"integrated\""), "expected kebab-case gpuClass in JSON: \(json)")
        XCTAssertTrue(json.contains("\"mid\""), "expected lower-case cpuClass in JSON: \(json)")
    }
}
