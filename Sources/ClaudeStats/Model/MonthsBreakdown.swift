import Foundation

enum MonthsBreakdown: String, CaseIterable, Identifiable {
    case total
    case type
    case model

    var id: String { rawValue }

    var label: String {
        switch self {
        case .total: return "Total"
        case .type: return "Type"
        case .model: return "Model"
        }
    }
}
