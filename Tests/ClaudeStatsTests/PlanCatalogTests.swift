import XCTest
@testable import ClaudeStats

final class PlanCatalogTests: XCTestCase {
    private func bundledFixture() -> Data {
        Data("""
        {
          "pro":     { "five_hour": { "tokens": 25000000 },  "seven_day": null },
          "max_5x":  { "five_hour": { "tokens": 120000000 }, "seven_day": { "tokens": 3500000000 } },
          "max_20x": { "five_hour": { "tokens": 480000000 }, "seven_day": { "tokens": 14000000000 } }
        }
        """.utf8)
    }

    func testReturnsBundledLimits() throws {
        let catalog = try PlanCatalog(bundledData: bundledFixture())
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .fiveHour)?.tokens, 120_000_000)
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .sevenDay)?.tokens, 3_500_000_000)
        XCTAssertNil(catalog.limit(plan: .pro, window: .sevenDay))
    }
}
