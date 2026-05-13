import Foundation

private struct StoredSample: Codable, Equatable {
    let ts: Int
    let localTokens: Int
    let utilization: Double
    let inferredLimit: Int
}

private struct StoredWindow: Codable {
    var samples: [StoredSample]
    var calibratedLimit: Int?
}

private struct StoredPlan: Codable {
    var five_hour: StoredWindow?
    var seven_day: StoredWindow?
}

private struct StoredFile: Codable {
    var pro: StoredPlan?
    var max_5x: StoredPlan?
    var max_20x: StoredPlan?
}

final class PlanCalibrator {
    static let minUtilization = 5.0
    static let maxSamples = 50
    static let outlierFactor = 3.0

    private let fileURL: URL
    private var data: StoredFile
    private let queue = DispatchQueue(label: "claude-stats.calibrator")

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(StoredFile.self, from: raw) {
            self.data = decoded
        } else {
            self.data = StoredFile(pro: nil, max_5x: nil, max_20x: nil)
        }
    }

    func calibrated(plan: PlanTier, window: Window) -> Int? {
        queue.sync { self.window(plan: plan, window: window)?.calibratedLimit }
    }

    func sampleCount(plan: PlanTier, window: Window) -> Int {
        queue.sync { self.window(plan: plan, window: window)?.samples.count ?? 0 }
    }

    func record(plan: PlanTier, window: Window,
                localTokens: Int, utilization: Double, now: Date) {
        queue.sync {
            guard utilization >= Self.minUtilization, localTokens > 0 else { return }
            let inferred = Int(Double(localTokens) / (utilization / 100.0))
            // Outlier guard against existing calibrated value.
            if let current = self.window(plan: plan, window: window)?.calibratedLimit, current > 0 {
                let lower = Double(current) / Self.outlierFactor
                let upper = Double(current) * Self.outlierFactor
                if Double(inferred) < lower || Double(inferred) > upper { return }
            }
            let sample = StoredSample(
                ts: Int(now.timeIntervalSince1970),
                localTokens: localTokens,
                utilization: utilization,
                inferredLimit: inferred
            )
            self.appendSample(sample, plan: plan, window: window)
            self.persistSnapshot()
        }
    }

    private func window(plan: PlanTier, window: Window) -> StoredWindow? {
        let stored: StoredPlan?
        switch plan {
        case .pro:     stored = data.pro
        case .max_5x:  stored = data.max_5x
        case .max_20x: stored = data.max_20x
        }
        switch window {
        case .fiveHour: return stored?.five_hour
        case .sevenDay: return stored?.seven_day
        }
    }

    private func appendSample(_ sample: StoredSample, plan: PlanTier, window: Window) {
        var perPlan = self.storedPlan(plan)
        var perWindow = (window == .fiveHour ? perPlan.five_hour : perPlan.seven_day)
                        ?? StoredWindow(samples: [], calibratedLimit: nil)
        perWindow.samples.append(sample)
        if perWindow.samples.count > Self.maxSamples {
            perWindow.samples.removeFirst(perWindow.samples.count - Self.maxSamples)
        }
        perWindow.calibratedLimit = Self.median(of: perWindow.samples.map { $0.inferredLimit })
        switch window {
        case .fiveHour: perPlan.five_hour = perWindow
        case .sevenDay: perPlan.seven_day = perWindow
        }
        writePlan(perPlan, for: plan)
    }

    private func storedPlan(_ plan: PlanTier) -> StoredPlan {
        switch plan {
        case .pro:     return data.pro     ?? StoredPlan()
        case .max_5x:  return data.max_5x  ?? StoredPlan()
        case .max_20x: return data.max_20x ?? StoredPlan()
        }
    }

    private func writePlan(_ stored: StoredPlan, for plan: PlanTier) {
        switch plan {
        case .pro:     data.pro = stored
        case .max_5x:  data.max_5x = stored
        case .max_20x: data.max_20x = stored
        }
    }

    private static func median(of values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    private func persistSnapshot() {
        // Atomic write: tmp file in same directory + rename.
        guard let raw = try? JSONEncoder().encode(data) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try raw.write(to: tmp, options: .atomic)
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
