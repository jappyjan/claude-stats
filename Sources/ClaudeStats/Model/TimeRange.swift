import Foundation

enum TimeRange: String, CaseIterable, Identifiable {
    case today
    case last7Days
    case last30Days
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .last7Days: return "7d"
        case .last30Days: return "30d"
        case .all: return "All"
        }
    }

    struct Bounds: Equatable {
        let start: Date
        let end: Date
    }

    func bounds(now: Date = Date(), calendar: Calendar = .current) -> Bounds {
        let midnight = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return Bounds(start: midnight, end: now)
        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -6, to: midnight) ?? midnight
            return Bounds(start: start, end: now)
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -29, to: midnight) ?? midnight
            return Bounds(start: start, end: now)
        case .all:
            return Bounds(start: Date(timeIntervalSince1970: 0), end: now)
        }
    }

    /// Window immediately preceding `bounds`. Nil for `.all`.
    func priorBounds(now: Date = Date(), calendar: Calendar = .current) -> Bounds? {
        guard self != .all else { return nil }
        let current = bounds(now: now, calendar: calendar)
        let priorEnd = current.start
        let dayCount: Int
        switch self {
        case .today: dayCount = 1
        case .last7Days: dayCount = 7
        case .last30Days: dayCount = 30
        case .all: return nil // unreachable due to guard above
        }
        let priorStart = calendar.date(byAdding: .day, value: -dayCount, to: priorEnd) ?? priorEnd
        return Bounds(start: priorStart, end: priorEnd)
    }
}
