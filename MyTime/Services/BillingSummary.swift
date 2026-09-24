import Foundation

enum BillingSummary {
    /// Does this entry count towards Uninvoiced $?
    /// Only unbilled, billable time on hourly projects — fixed-fee time never does.
    static func countsAsUninvoiced(_ entry: TimeEntry) -> Bool {
        guard entry.billingState == .unbilled, entry.isBillable,
              RateResolver.isBillable(entry.task),
              entry.task?.project?.billingType == .hourly else { return false }
        return true
    }

    /// Whole minutes as shown on the timesheet, which is what invoices bill.
    static func wholeMinutes(_ entry: TimeEntry, at now: Date = .now) -> Int {
        Int(entry.liveDuration(at: now).rounded(.down)) / 60
    }

    /// Money for whole minutes, multiplied before dividing so 0:41 at $150 is exactly $102.50.
    static func amount(minutes: Int, rate: Decimal) -> Decimal {
        Money.round(Decimal(minutes) * rate / 60)
    }

    static func value(of entry: TimeEntry, at now: Date = .now) -> Decimal {
        amount(minutes: wholeMinutes(entry, at: now), rate: RateResolver.rate(for: entry.task))
    }

    /// Matches what an invoice would charge: whole minutes, summed per rate, then priced.
    static func uninvoicedAmount(_ entries: [TimeEntry], at now: Date = .now) -> Decimal {
        var minutesByRate: [Decimal: Int] = [:]
        for entry in entries where countsAsUninvoiced(entry) {
            minutesByRate[RateResolver.rate(for: entry.task), default: 0] += wholeMinutes(entry, at: now)
        }
        return minutesByRate.reduce(0) { $0 + amount(minutes: $1.value, rate: $1.key) }
    }

    static func totalSeconds(_ entries: [TimeEntry], at now: Date = .now) -> TimeInterval {
        entries.reduce(0) { $0 + $1.liveDuration(at: now) }
    }

    static func billableSeconds(_ entries: [TimeEntry], at now: Date = .now) -> TimeInterval {
        entries.filter { $0.isBillable && RateResolver.isBillable($0.task) }
            .reduce(0) { $0 + $1.liveDuration(at: now) }
    }
}
