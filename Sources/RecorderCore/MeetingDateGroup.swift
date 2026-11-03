import Foundation

public enum MeetingDateGroup: CaseIterable, Sendable {
    case today, yesterday, previousSevenDays, previousThirtyDays, older, future

    public var title: String {
        switch self {
        case .today: return "오늘"
        case .yesterday: return "어제"
        case .previousSevenDays: return "이전 7일"
        case .previousThirtyDays: return "이전 30일"
        case .older: return "그 이전"
        case .future: return "예정"
        }
    }

    public static func group(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> Self {
        let beginning = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: beginning).day ?? 0
        switch days {
        case ..<0: return .future
        case 0: return .today
        case 1: return .yesterday
        case 2...7: return .previousSevenDays
        case 8...30: return .previousThirtyDays
        default: return .older
        }
    }
}
