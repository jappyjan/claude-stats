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

private struct CalibrationFile: Decodable {
    let pro: PerPlan?
    let max_5x: PerPlan?
    let max_20x: PerPlan?
    struct PerPlan: Decodable {
        let five_hour: PerWindow?
        let seven_day: PerWindow?
    }
    struct PerWindow: Decodable {
        let calibratedLimit: Int?
    }
}

/// Per-plan limit lookup. Loads bundled fallback values and overlays
/// them with the user's calibration file if one exists.
///
/// Not thread-safe. All reads and writes must happen on the same
/// actor — in this app, that's the main actor via `StatsViewModel`.
final class PlanCatalog {
    private let bundled: BundledLimits
    private let calibrationURL: URL
    private var calibration: CalibrationFile?

    init(bundledData: Data, calibrationURL: URL) throws {
        self.bundled = try JSONDecoder().decode(BundledLimits.self, from: bundledData)
        self.calibrationURL = calibrationURL
        loadCalibration()
    }

    func reloadCalibration() {
        loadCalibration()
    }

    private func loadCalibration() {
        guard let data = try? Data(contentsOf: calibrationURL) else {
            calibration = nil
            return
        }
        calibration = try? JSONDecoder().decode(CalibrationFile.self, from: data)
    }

    func limit(plan: PlanTier, window: Window) -> WindowLimit? {
        if let calibrated = calibratedValue(plan: plan, window: window) {
            return WindowLimit(tokens: calibrated)
        }
        return bundledValue(plan: plan, window: window)
    }

    private func bundledValue(plan: PlanTier, window: Window) -> WindowLimit? {
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

    private func calibratedValue(plan: PlanTier, window: Window) -> Int? {
        guard let calibration else { return nil }
        let perPlan: CalibrationFile.PerPlan?
        switch plan {
        case .pro:     perPlan = calibration.pro
        case .max_5x:  perPlan = calibration.max_5x
        case .max_20x: perPlan = calibration.max_20x
        }
        let perWindow: CalibrationFile.PerWindow?
        switch window {
        case .fiveHour: perWindow = perPlan?.five_hour
        case .sevenDay: perWindow = perPlan?.seven_day
        }
        return perWindow?.calibratedLimit
    }
}
