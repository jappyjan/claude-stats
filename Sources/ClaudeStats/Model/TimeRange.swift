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
            return Bounds(start: midnight.addingTimeInterval(-6 * 86400), end: now)
        case .last30Days:
            return Bounds(start: midnight.addingTimeInterval(-29 * 86400), end: now)
        case .all:
            return Bounds(start: Date(timeIntervalSince1970: 0), end: now)
        }
    }

    /// Window immediately preceding `bounds`. Nil for `.all`.
    /// Shift = (midnight - current.start) + 86400, so that `.today` yields the full
    /// prior calendar day and `.last7Days` / `.last30Days` yield their equal-length
    /// full-day windows immediately before the current period.
    func priorBounds(now: Date = Date(), calendar: Calendar = .current) -> Bounds? {
        guard self != .all else { return nil }
        let current = bounds(now: now, calendar: calendar)
        let midnight = calendar.startOfDay(for: now)
        let shift = midnight.timeIntervalSince(current.start) + 86400
        return Bounds(
            start: current.start.addingTimeInterval(-shift),
            end: current.start
        )
    }
}
