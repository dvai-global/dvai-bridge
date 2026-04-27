// Smoke test for DVAICapacitorMLX. Just verifies the bundle loads and
// the underlying MLXPluginState boots into the not-running state.

import XCTest
@testable import DVAICapacitorMLX
import DVAIMLXCore

final class SmokeTest: XCTestCase {
    func testMLXPluginStateInitiallyNotRunning() async {
        let state = MLXPluginState()
        let info = await state.statusInfo()
        XCTAssertEqual(info["running"] as? Bool, false)
    }
}
