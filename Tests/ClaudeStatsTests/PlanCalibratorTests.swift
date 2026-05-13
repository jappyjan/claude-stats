import XCTest
@testable import ClaudeStats

final class PlanCalibratorTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("calib-\(UUID().uuidString).json")
    }

    func testFirstAcceptedSampleSetsCalibratedLimit() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = PlanCalibrator(fileURL: url)
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 500_000, utilization: 50.0,
                   now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(cal.calibrated(plan: .max_5x, window: .fiveHour), 1_000_000)
        XCTAssertEqual(cal.sampleCount(plan: .max_5x, window: .fiveHour), 1)
    }

    func testLowUtilizationSampleRejected() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = PlanCalibrator(fileURL: url)
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 1000, utilization: 1.0,
                   now: Date(timeIntervalSince1970: 1))
        XCTAssertNil(cal.calibrated(plan: .max_5x, window: .fiveHour))
        XCTAssertEqual(cal.sampleCount(plan: .max_5x, window: .fiveHour), 0)
    }

    func testZeroLocalTokensRejected() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = PlanCalibrator(fileURL: url)
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 0, utilization: 50.0,
                   now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(cal.sampleCount(plan: .max_5x, window: .fiveHour), 0)
    }

    func testOutlier3xGuardRejects() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = PlanCalibrator(fileURL: url)
        for i in 0..<5 {
            cal.record(plan: .max_5x, window: .fiveHour,
                       localTokens: 500_000, utilization: 50.0,
                       now: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        XCTAssertEqual(cal.calibrated(plan: .max_5x, window: .fiveHour), 1_000_000)

        // Now an outlier: tokens are 100x larger but utilization low (implies 5M limit).
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 1_000_000, utilization: 20.0,
                   now: Date(timeIntervalSince1970: 100))
        // 1_000_000 / 0.20 = 5_000_000, which is 5x the established 1M — outside the 3x gate.
        XCTAssertEqual(cal.calibrated(plan: .max_5x, window: .fiveHour), 1_000_000)
    }

    func testMedianUsedAcrossSamples() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = PlanCalibrator(fileURL: url)
        // First sample establishes baseline at 1.0M.
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 500_000, utilization: 50.0,
                   now: Date(timeIntervalSince1970: 1))
        // Additional samples within the 3x guard ([333K, 3M]) refine the median.
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 540_000, utilization: 50.0,  // inferred 1.08M
                   now: Date(timeIntervalSince1970: 2))
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 1_200_000, utilization: 50.0, // inferred 2.4M (within 3x of 1.08M after update)
                   now: Date(timeIntervalSince1970: 3))
        let cal2 = cal.calibrated(plan: .max_5x, window: .fiveHour) ?? 0
        // Median of {1_000_000, 1_080_000, 2_400_000} = 1_080_000.
        XCTAssertEqual(cal2, 1_080_000)
    }

    func testWritePersistsAcrossInstances() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let cal = PlanCalibrator(fileURL: url)
            cal.record(plan: .max_5x, window: .fiveHour,
                       localTokens: 500_000, utilization: 50.0,
                       now: Date(timeIntervalSince1970: 1))
        }
        let cal2 = PlanCalibrator(fileURL: url)
        XCTAssertEqual(cal2.calibrated(plan: .max_5x, window: .fiveHour), 1_000_000)
    }

    func testTrimToFiftySamples() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = PlanCalibrator(fileURL: url)
        for i in 0..<60 {
            cal.record(plan: .max_5x, window: .fiveHour,
                       localTokens: 500_000, utilization: 50.0,
                       now: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        XCTAssertEqual(cal.sampleCount(plan: .max_5x, window: .fiveHour), 50)
    }
}
