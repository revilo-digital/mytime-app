import SwiftData
import SwiftUI

/// Today / This week / Billable / Uninvoiced $ — always relative to the real current week.
struct TotalsBar: View {
    @Query private var thisWeek: [TimeEntry]
    @Query private var unbilled: [TimeEntry]

    init() {
        let start = Week.start(of: .now)
        let end = Week.end(from: start)
        _thisWeek = Query(filter: #Predicate<TimeEntry> { $0.date >= start && $0.date < end })
        let unbilledRaw = BillingState.unbilled.rawValue
        _unbilled = Query(filter: #Predicate<TimeEntry> { $0.billingStateRaw == unbilledRaw })
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let today = Calendar.current.startOfDay(for: context.date)
            HStack(spacing: 12) {
                stat("Today", DurationFormat.short(BillingSummary.totalSeconds(thisWeek.filter { $0.date == today }, at: context.date)),
                     systemImage: "sun.max")
                stat("This week", DurationFormat.short(BillingSummary.totalSeconds(thisWeek, at: context.date)),
                     systemImage: "calendar")
                stat("Billable this week", DurationFormat.short(BillingSummary.billableSeconds(thisWeek, at: context.date)),
                     systemImage: "checkmark.circle")
                stat("Uninvoiced", Money.format(BillingSummary.uninvoicedAmount(unbilled, at: context.date)),
                     systemImage: "dollarsign.circle", tint: .green)
                    .help("Unbilled, billable time on hourly projects at current rates")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func stat(_ title: String, _ value: String, systemImage: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint ?? .secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .card(padding: 12, cornerRadius: 12, tint: tint)
    }
}
