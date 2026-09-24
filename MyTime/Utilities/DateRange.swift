import Foundation

/// Weeks run Monday to Sunday.
enum Week {
    static var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal
    }

    static func start(of date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func days(from weekStart: Date) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    static func end(from weekStart: Date) -> Date {
        calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
    }

    /// "22 – 28 Sep 2026"
    static func title(from weekStart: Date) -> String {
        let last = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let sameMonth = calendar.isDate(weekStart, equalTo: last, toGranularity: .month)
        let first = weekStart.formatted(sameMonth ? .dateTime.day() : .dateTime.day().month(.abbreviated))
        return "\(first) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
    }
}
