import Foundation

private struct BundledLimits: Decodable {
    let pro: PerPlan
    let max_5x: PerPlan
    let max_20x: PerPlan
    struct PerPlan: Decodable {
        let five_hour: WindowLimit?
        let seven_day: WindowLimit?
    }
}

/// Per-plan limit lookup using bundled fallback values.
final class PlanCatalog {
    private let bundled: BundledLimits

    init(bundledData: Data) throws {
        self.bundled = try JSONDecoder().decode(BundledLimits.self, from: bundledData)
    }

    func limit(plan: PlanTier, window: Window) -> WindowLimit? {
        let perPlan: BundledLimits.PerPlan
        switch plan {
        case .pro:     perPlan = bundled.pro
        case .max_5x:  perPlan = bundled.max_5x
        case .max_20x: perPlan = bundled.max_20x
        }
        switch window {
        case .fiveHour: return perPlan.five_hour
        case .sevenDay: return perPlan.seven_day
        }
    }
}
