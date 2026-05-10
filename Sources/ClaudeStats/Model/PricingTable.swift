import Foundation

struct PricingTable {
    struct Rate: Equatable {
        let input: Double
        let output: Double
        let cacheCreate: Double
        let cacheRead: Double
    }

    private let rates: [String: Rate]

    init(rates: [String: Rate]) { self.rates = rates }

    func rate(for model: String) -> Rate? { rates[model] }

    func cost(for entry: UsageEntry) -> Double? {
        guard let r = rates[entry.model] else { return nil }
        return Double(entry.inputTokens) * r.input
            + Double(entry.outputTokens) * r.output
            + Double(entry.cacheCreationTokens) * r.cacheCreate
            + Double(entry.cacheReadTokens) * r.cacheRead
    }

    /// Cost for a flat token breakdown — used by `UsageStore` aggregations.
    func cost(model: String, input: Int, output: Int, cacheCreate: Int, cacheRead: Int) -> Double? {
        guard let r = rates[model] else { return nil }
        return Double(input) * r.input
            + Double(output) * r.output
            + Double(cacheCreate) * r.cacheCreate
            + Double(cacheRead) * r.cacheRead
    }

    func totalCost(for entries: [UsageEntry]) -> Double {
        entries.reduce(0.0) { acc, e in acc + (cost(for: e) ?? 0) }
    }

    static func fromJSON(_ data: Data) throws -> PricingTable {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "PricingTable", code: 1)
        }
        var out: [String: Rate] = [:]
        for (model, raw) in obj {
            guard let dict = raw as? [String: Any] else { continue }
            let input = (dict["input_cost_per_token"] as? Double) ?? 0
            let output = (dict["output_cost_per_token"] as? Double) ?? 0
            let cacheCreate = (dict["cache_creation_input_token_cost"] as? Double) ?? 0
            let cacheRead = (dict["cache_read_input_token_cost"] as? Double) ?? 0
            // Only keep entries that at least have input+output costs.
            if input > 0 || output > 0 {
                out[model] = Rate(input: input, output: output, cacheCreate: cacheCreate, cacheRead: cacheRead)
            }
        }
        return PricingTable(rates: out)
    }
}
