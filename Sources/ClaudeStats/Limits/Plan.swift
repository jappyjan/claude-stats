import Foundation

enum PlanTier: String, Codable, CaseIterable, Equatable {
    case pro
    case max_5x
    case max_20x

    var displayName: String {
        switch self {
        case .pro:     return "Pro"
        case .max_5x:  return "Max 5x"
        case .max_20x: return "Max 20x"
        }
    }
}

enum Window: String, Codable, CaseIterable, Equatable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"

    var seconds: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 3600
        case .sevenDay: return 7 * 86400
        }
    }

    var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        }
    }
}

struct WindowLimit: Equatable, Codable {
    let tokens: Int
}
