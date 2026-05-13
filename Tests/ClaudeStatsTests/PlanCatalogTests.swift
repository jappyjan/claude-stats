import XCTest
@testable import ClaudeStats

final class PlanCatalogTests: XCTestCase {
    private func bundledFixture() -> Data {
        Data("""
        {
          "pro":     { "five_hour": { "tokens": 3500000 },  "seven_day": null },
          "max_5x":  { "five_hour": { "tokens": 17000000 }, "seven_day": { "tokens": 490000000 } },
          "max_20x": { "five_hour": { "tokens": 67000000 }, "seven_day": { "tokens": 1950000000 } }
        }
        """.utf8)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("calib-\(UUID().uuidString).json")
    }

    func testReturnsBundledLimitWhenNoCalibration() throws {
        let url = tempURL()
        let catalog = try PlanCatalog(bundledData: bundledFixture(), calibrationURL: url)
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .fiveHour)?.tokens, 17_000_000)
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .sevenDay)?.tokens, 490_000_000)
        XCTAssertNil(catalog.limit(plan: .pro, window: .sevenDay))
    }

    func testCalibrationOverlayShadowsBundled() throws {
        let url = tempURL()
        let calibration = """
        {
          "max_5x": { "five_hour": { "calibratedLimit": 1300000 } }
        }
        """
        try calibration.write(to: url, atomically: true, encoding: .utf8)
        let catalog = try PlanCatalog(bundledData: bundledFixture(), calibrationURL: url)
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .fiveHour)?.tokens, 1_300_000)
        // Non-calibrated window still falls through to bundled.
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .sevenDay)?.tokens, 490_000_000)
        try? FileManager.default.removeItem(at: url)
    }

    func testReloadCalibrationPicksUpFileChanges() throws {
        let url = tempURL()
        let catalog = try PlanCatalog(bundledData: bundledFixture(), calibrationURL: url)
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .fiveHour)?.tokens, 17_000_000)

        try """
        {"max_5x": {"five_hour": {"calibratedLimit": 1400000}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        catalog.reloadCalibration()
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .fiveHour)?.tokens, 1_400_000)
        try? FileManager.default.removeItem(at: url)
    }
}
