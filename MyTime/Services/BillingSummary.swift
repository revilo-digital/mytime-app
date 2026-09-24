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

    static func value(of entry: TimeEntry, at now: Date = .now) -> Decimal {
        Money.round(DurationFormat.hours(entry.liveDuration(at: now)) * RateResolver.rate(for: entry.task))
    }

    static func uninvoicedAmount(_ entries: [TimeEntry], at now: Date = .now) -> Decimal {
        entries.filter(countsAsUninvoiced).reduce(0) { $0 + value(of: $1, at: now) }
    }

    static func totalSeconds(_ entries: [TimeEntry], at now: Date = .now) -> TimeInterval {
        entries.reduce(0) { $0 + $1.liveDuration(at: now) }
    }

    static func billableSeconds(_ entries: [TimeEntry], at now: Date = .now) -> TimeInterval {
        entries.filter { $0.isBillable && RateResolver.isBillable($0.task) }
            .reduce(0) { $0 + $1.liveDuration(at: now) }
    }
}
