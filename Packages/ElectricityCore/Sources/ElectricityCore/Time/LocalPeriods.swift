import Foundation

/// Local calendar periods. Records are stored in UTC; "today" and "this week" use the user's
/// time zone and first weekday (SPEC 4.4).
public enum LocalPeriod: Sendable, Hashable {
    case day
    case week
    case month
    case year

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// The period containing `date` in `calendar`. The calendar's time zone and `firstWeekday` apply.
    public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        // `dateInterval(of:for:)` only fails for unsupported components; all cases here are supported.
        calendar.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 0)
    }
}
