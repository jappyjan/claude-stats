import XCTest
@testable import ClaudeStats

final class TimeRangeTests: XCTestCase {
    // Reference moment: 2026-05-10 14:00:00 UTC
    let now = Date(timeIntervalSince1970: 1778423400)

    func testTodayStartsAtLocalMidnight() {
        let r = TimeRange.today.bounds(now: now, calendar: utc())
        XCTAssertEqual(r.start, Date(timeIntervalSince1970: 1778371200)) // 2026-05-10 00:00 UTC
        XCTAssertEqual(r.end, now)
    }

    func testSevenDaysGoesBackSevenFullDays() {
        let r = TimeRange.last7Days.bounds(now: now, calendar: utc())
        // Start = midnight 6 days before today's midnight (so 7 days inclusive)
        XCTAssertEqual(r.start, Date(timeIntervalSince1970: 1778371200 - 6 * 86400))
        XCTAssertEqual(r.end, now)
    }

    func testThirtyDaysGoesBackThirty() {
        let r = TimeRange.last30Days.bounds(now: now, calendar: utc())
        XCTAssertEqual(r.start, Date(timeIntervalSince1970: 1778371200 - 29 * 86400))
        XCTAssertEqual(r.end, now)
    }

    func testAllStartsAtEpoch() {
        let r = TimeRange.all.bounds(now: now, calendar: utc())
        XCTAssertEqual(r.start, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(r.end, now)
    }

    func testPriorPeriodTodayIsYesterday() {
        let r = TimeRange.today.priorBounds(now: now, calendar: utc())
        let yesterdayStart = Date(timeIntervalSince1970: 1778371200 - 86400)
        XCTAssertEqual(r?.start, yesterdayStart)
        XCTAssertEqual(r?.end, Date(timeIntervalSince1970: 1778371200))
    }

    func testPriorPeriodAllIsNil() {
        XCTAssertNil(TimeRange.all.priorBounds(now: now, calendar: utc()))
    }

    private func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
}
