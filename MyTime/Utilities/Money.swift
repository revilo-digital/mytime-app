import Foundation

enum Money {
    static let currencyCode = "NZD"
    /// Pinned so NZD shows as "$150.00" rather than "NZ$150.00" on non-NZ system locales.
    static let locale = Locale(identifier: "en_NZ")

    static func format(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: currencyCode).locale(locale))
    }

    /// Rounds half-up to cents.
    static func round(_ amount: Decimal, scale: Int = 2) -> Decimal {
        var value = amount
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}

enum HoursFormat {
    /// "26h 45min", matching the Harvest invoice footer.
    static func long(_ hours: Decimal) -> String {
        let totalMinutes = minutes(hours)
        let h = totalMinutes / 60, m = totalMinutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)min"
    }

    /// "1:45" — hours and minutes. Decimal hours are only used internally for money.
    static func clock(_ hours: Decimal) -> String {
        let m = minutes(hours)
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// Whole minutes in a decimal-hours quantity.
    static func minutes(_ hours: Decimal) -> Int {
        Int(truncating: Money.round(hours * 60, scale: 0) as NSNumber)
    }
}

enum TaxFormat {
    /// 0.15 → "15%"
    static func percent(_ rate: Decimal) -> String {
        rate.formatted(.percent.precision(.fractionLength(0...2)))
    }
}
