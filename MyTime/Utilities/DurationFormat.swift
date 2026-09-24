import Foundation

enum DurationFormat {
    /// "1:42:07"
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "1:42" — hours and minutes, as shown in the menu bar and timesheet.
    static func short(_ seconds: TimeInterval) -> String {
        let m = Int(seconds.rounded(.down)) / 60
        return String(format: "%d:%02d", m / 60, m % 60)
    }
}

extension DurationFormat {
    /// Parses "1:30", "1.5", "1.5h", "90m", "1h 30m" or "45" (minutes if > 12, else hours).
    static func parse(_ text: String) -> TimeInterval? {
        let s = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        if s.contains(":") {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let h = Int(parts[0].isEmpty ? "0" : parts[0]), let m = Int(parts[1]), m < 60 else { return nil }
            return TimeInterval(h * 3600 + m * 60)
        }

        if s.contains("h") || s.contains("m") {
            var total: Double = 0
            var number = ""
            for ch in s {
                if ch.isNumber || ch == "." { number.append(ch); continue }
                if ch == "h", let v = Double(number) { total += v * 3600; number = "" }
                else if ch == "m", let v = Double(number) { total += v * 60; number = "" }
                else if ch != " " { return nil }
            }
            guard number.isEmpty else { return nil }
            return total
        }

        guard let value = Double(s), value >= 0 else { return nil }
        // A bare whole number above 12 reads more naturally as minutes ("45").
        if value > 12, value == value.rounded() { return value * 60 }
        return value * 3600
    }

    /// Decimal hours, e.g. 1.25 for 1:15.
    static func hours(_ seconds: TimeInterval) -> Decimal {
        Decimal(seconds) / 3600
    }
}
