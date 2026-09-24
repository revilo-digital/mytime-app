import Foundation
import SwiftData
import Testing
@testable import MyTime

@MainActor
struct TimesheetLogicTests {
    let container: ModelContainer
    let context: ModelContext
    let hourlyTask: TaskType
    let fixedTask: TaskType
    let day = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        let client = Client(name: "Acme", defaultRate: 150)
        let hourly = Project(name: "Support", client: client)
        let fixed = Project(name: "Rebuild", client: client, billingType: .fixedFee)
        hourlyTask = TaskType(name: "Dev", project: hourly)
        fixedTask = TaskType(name: "Dev", project: fixed)
        context.insert(client)
        context.insert(hourly)
        context.insert(fixed)
        context.insert(hourlyTask)
        context.insert(fixedTask)
    }

    private func entry(_ task: TaskType, hours: Double) -> TimeEntry {
        let e = TimeEntry(task: task, date: day, durationSeconds: hours * 3600)
        context.insert(e)
        return e
    }

    @Test(arguments: [
        ("1:30", 5400.0), ("0:45", 2700), ("1.5", 5400), ("1.5h", 5400), ("90m", 5400),
        ("1h 30m", 5400), ("45", 2700), ("2", 7200), (":15", 900),
    ])
    func parsesDurations(input: String, seconds: Double) {
        #expect(DurationFormat.parse(input) == seconds)
    }

    @Test(arguments: ["", "abc", "1:75", "-1", "1x"])
    func rejectsBadDurations(input: String) {
        #expect(DurationFormat.parse(input) == nil)
    }

    @Test func uninvoicedCountsHourlyUnbilledOnly() {
        _ = entry(hourlyTask, hours: 2)          // $300
        _ = entry(fixedTask, hours: 5)           // fixed fee: excluded
        entry(hourlyTask, hours: 1).billingState = .billed
        entry(hourlyTask, hours: 1).billingState = .writtenOff
        entry(hourlyTask, hours: 1).isBillable = false
        let all = (try? context.fetch(FetchDescriptor<TimeEntry>())) ?? []
        #expect(BillingSummary.uninvoicedAmount(all) == 300)
    }

    @Test func uninvoicedRoundsToCents() {
        hourlyTask.rateOverride = 100
        _ = entry(hourlyTask, hours: 1.0 / 3)    // 0:20 → 33.333… → 33.33
        let all = (try? context.fetch(FetchDescriptor<TimeEntry>())) ?? []
        #expect(BillingSummary.uninvoicedAmount(all) == Decimal(string: "33.33")!)
    }

    @Test func uninvoicedBillsWholeMinutesLikeInvoices() {
        // 2:36:53 at $150: seconds would give $392.22, but invoices bill 2:36 = $390.00.
        _ = entry(hourlyTask, hours: (156 * 60 + 53) / 3600)
        let all = (try? context.fetch(FetchDescriptor<TimeEntry>())) ?? []
        #expect(BillingSummary.uninvoicedAmount(all) == 390)
    }

    @Test func weekStartsOnMonday() {
        // 2026-09-23 is a Wednesday.
        let wed = Week.calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 15))!
        let start = Week.start(of: wed)
        #expect(Week.calendar.component(.weekday, from: start) == 2)
        #expect(Week.calendar.component(.day, from: start) == 21)
        #expect(Week.days(from: start).count == 7)
    }
}
