import XCTest
@testable import ClaudeStats

final class PricingTableTests: XCTestCase {
    func testCostForKnownModel() {
        let table = PricingTable(rates: [
            "claude-opus-4-7": .init(input: 0.000015, output: 0.000075, cacheCreate: 0.00001875, cacheRead: 0.0000015)
        ])
        let entry = UsageEntry(
            timestamp: Date(), sessionId: "s", projectPath: "/p", model: "claude-opus-4-7",
            inputTokens: 1000, outputTokens: 500,
            cacheCreationTokens: 200, cacheReadTokens: 10000
        )
        let cost = table.cost(for: entry)
        // 1000*1.5e-5 + 500*7.5e-5 + 200*1.875e-5 + 10000*1.5e-6
        // = 0.015 + 0.0375 + 0.00375 + 0.015 = 0.07125
        XCTAssertEqual(cost ?? 0, 0.07125, accuracy: 1e-9)
    }

    func testCostForUnknownModelReturnsNil() {
        let table = PricingTable(rates: [:])
        let entry = UsageEntry(
            timestamp: Date(), sessionId: "s", projectPath: "/p", model: "claude-unknown",
            inputTokens: 1000, outputTokens: 500, cacheCreationTokens: 0, cacheReadTokens: 0
        )
        XCTAssertNil(table.cost(for: entry))
    }

    func testFromJSONParsesLiteLLMShape() throws {
        let json = #"""
        {
          "claude-opus-4-7": {
            "input_cost_per_token": 0.000015,
            "output_cost_per_token": 0.000075,
            "cache_creation_input_token_cost": 0.00001875,
            "cache_read_input_token_cost": 0.0000015,
            "max_tokens": 8192
          },
          "gpt-4": {
            "input_cost_per_token": 0.00003,
            "output_cost_per_token": 0.00006
          }
        }
        """#
        let table = try PricingTable.fromJSON(Data(json.utf8))
        XCTAssertNotNil(table.rate(for: "claude-opus-4-7"))
        XCTAssertEqual(table.rate(for: "claude-opus-4-7")?.input, 0.000015)
        // Non-anthropic entries are still loaded; we just don't surface them.
        XCTAssertNotNil(table.rate(for: "gpt-4"))
    }

    func testTotalCostAggregatedAcrossEntries() {
        let table = PricingTable(rates: [
            "m": .init(input: 1, output: 2, cacheCreate: 3, cacheRead: 4)
        ])
        let entries = [
            UsageEntry(timestamp: Date(), sessionId: "s", projectPath: "/p", model: "m",
                       inputTokens: 1, outputTokens: 1, cacheCreationTokens: 1, cacheReadTokens: 1),
            UsageEntry(timestamp: Date(), sessionId: "s", projectPath: "/p", model: "m",
                       inputTokens: 1, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0),
        ]
        XCTAssertEqual(table.totalCost(for: entries), 11)
    }
}
