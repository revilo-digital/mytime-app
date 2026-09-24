import Foundation
import SwiftData
import Testing
@testable import MyTime

@MainActor
struct InvoiceBuilderTests {
    let container: ModelContainer
    let context: ModelContext
    let client: Client
    let dev: TaskType
    let meetings: TaskType
    let fixedTask: TaskType
    let settings: BusinessSettings
    let day = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        client = Client(name: "Acme", defaultRate: 150)
        let support = Project(name: "Support", client: client)
        let rebuild = Project(name: "Rebuild", client: client, billingType: .fixedFee)
        dev = TaskType(name: "Dev", project: support)
        meetings = TaskType(name: "Meetings", project: support)
        meetings.rateOverride = 100
        fixedTask = TaskType(name: "Build", project: rebuild)
        context.insert(client)
        context.insert(support)
        context.insert(rebuild)
        context.insert(dev)
        context.insert(meetings)
        context.insert(fixedTask)
        settings = BusinessSettings.current(in: context)
    }

    private func entry(_ task: TaskType, minutes: Double, note: String = "") -> TimeEntry {
        let e = TimeEntry(task: task, date: day, durationSeconds: minutes * 60, note: note)
        context.insert(e)
        return e
    }

    private func unbilledTotal() -> Decimal {
        BillingSummary.uninvoicedAmount((try? context.fetch(FetchDescriptor<TimeEntry>())) ?? [])
    }

    @Test func groupsByTaskAndRate() {
        let entries = [entry(dev, minutes: 90), entry(dev, minutes: 30), entry(meetings, minutes: 60)]
        let lines = InvoiceBuilder.hourlyLines(for: entries, grouping: .task, roundingMinutes: 0)
        #expect(lines == [
            LineSpec(description: "Support - Dev", hours: 2, rate: 150, amount: 300),
            LineSpec(description: "Support - Meetings", hours: 1, rate: 100, amount: 100),
        ])
    }

    @Test func projectThenTaskGroupingDedupesNotes() {
        let other = Project(name: "Another", client: client)
        let otherTask = TaskType(name: "Dev", project: other)
        context.insert(other)
        context.insert(otherTask)
        let entries = [
            entry(dev, minutes: 60, note: "WIP"),
            entry(meetings, minutes: 30, note: "Standup"),
            entry(dev, minutes: 30, note: "wip"),          // duplicate note, different case
            entry(dev, minutes: 15, note: "End2End"),
            entry(otherTask, minutes: 60),
        ]
        let lines = InvoiceBuilder.hourlyLines(for: entries, grouping: .projectTask, roundingMinutes: 0)
        #expect(lines.map(\.groupTitle) == ["Another", "Support", "Support"])
        #expect(lines.map(\.description) == ["Dev", "Dev", "Meetings"])
        #expect(lines[1].hours == Decimal(string: "1.75")!)
        #expect(lines[1].details == "WIP · End2End")
        #expect(lines[1].amount == Decimal(string: "262.5")!)
        #expect(lines[2].details == "Standup")
    }

    @Test func projectGroupingStillSplitsByRate() {
        let entries = [entry(dev, minutes: 60), entry(meetings, minutes: 60)]
        let lines = InvoiceBuilder.hourlyLines(for: entries, grouping: .project, roundingMinutes: 0)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.description == "Support" })
    }

    @Test func everyEntryGroupingKeepsLinesSeparate() {
        let entries = [entry(dev, minutes: 60, note: "Fix login"), entry(dev, minutes: 60, note: "Fix login")]
        let lines = InvoiceBuilder.hourlyLines(for: entries, grouping: .entry, roundingMinutes: 0)
        #expect(lines.count == 2)
        #expect(lines[0].description == "Support - Dev: Fix login")
    }

    @Test func lineDetailOptionsShapeLabels() {
        let e = entry(dev, minutes: 60, note: "Fix login")
        let taskOnly = InvoiceBuilder.hourlyLines(for: [e], grouping: .entry, roundingMinutes: 0, include: [.task])
        #expect(taskOnly[0].description == "Dev")
        let withDate = InvoiceBuilder.hourlyLines(for: [e], grouping: .entry, roundingMinutes: 0, include: [.project, .date, .notes])
        #expect(withDate[0].description == "Support - \(DateText.short(e.date)): Fix login")
        let noNotes = InvoiceBuilder.hourlyLines(for: [e], grouping: .projectTask, roundingMinutes: 0, include: [.date])
        #expect(noNotes[0].details == DateText.short(e.date))
    }

    @Test func roundsEachEntryUpToIncrement() {
        let e = entry(dev, minutes: 7)
        #expect(InvoiceBuilder.billableHours(e, roundingMinutes: 6) == Decimal(string: "0.2")!)   // 12 min
        #expect(InvoiceBuilder.billableHours(e, roundingMinutes: 15) == Decimal(string: "0.25")!)
        #expect(InvoiceBuilder.billableMinutes(e, roundingMinutes: 0) == 7)                       // real time, no decimal rounding
    }

    @Test func createsInvoiceWithGSTAndNumbering() {
        let billed = [entry(dev, minutes: 120)]
        let invoice = InvoiceBuilder.createInvoice(client: client, bill: billed, cover: [], grouping: .task,
                                                   fixedLines: [], issueDate: day, settings: settings, context: context)
        #expect(invoice.number == "1")
        #expect(settings.nextInvoiceNumber == 2)
        #expect(invoice.subject == "Contracting")
        #expect(invoice.subtotal == 300)
        #expect(invoice.taxAmount == 45)
        #expect(invoice.total == 345)
        #expect(billed[0].billingState == .billed)
        #expect(billed[0].isLocked)
        #expect(unbilledTotal() == 0)
    }

    @Test func fixedFeeInvoiceCoversHoursWithoutHourlyLines() {
        let covered = [entry(fixedTask, minutes: 600), entry(dev, minutes: 60)]
        let invoice = InvoiceBuilder.createInvoice(
            client: client, bill: [], cover: covered, grouping: .task,
            fixedLines: [FixedLineInput(description: "Phase 1 – agreed fee", amount: 4000)],
            settings: settings, context: context
        )
        #expect(invoice.lines.count == 1)
        #expect(invoice.lines[0].kind == .fixed)
        #expect(invoice.subtotal == 4000)
        #expect(invoice.total == 4600)
        #expect(covered.allSatisfy { $0.billingState == .covered && $0.invoice === invoice })
        #expect(unbilledTotal() == 0)
    }

    @Test func deletingDraftFreesEntriesAndRollsBackNumber() {
        let billed = [entry(dev, minutes: 60)]
        let covered = [entry(fixedTask, minutes: 60)]
        let invoice = InvoiceBuilder.createInvoice(client: client, bill: billed, cover: covered, grouping: .task,
                                                   fixedLines: [], settings: settings, context: context)
        InvoiceBuilder.deleteDraft(invoice, settings: settings, context: context)
        #expect(billed[0].billingState == .unbilled && billed[0].invoice == nil)
        #expect(covered[0].billingState == .unbilled)
        #expect(settings.nextInvoiceNumber == 1)
        #expect(unbilledTotal() == 150)
    }

    @Test func deletingOlderDraftLeavesNumberGap() {
        let first = InvoiceBuilder.createInvoice(client: client, bill: [entry(dev, minutes: 60)], cover: [], grouping: .task,
                                                 fixedLines: [], settings: settings, context: context)
        _ = InvoiceBuilder.createInvoice(client: client, bill: [entry(dev, minutes: 60)], cover: [], grouping: .task,
                                         fixedLines: [], settings: settings, context: context)
        InvoiceBuilder.deleteDraft(first, settings: settings, context: context)
        #expect(settings.nextInvoiceNumber == 3)
    }

    @Test func sentInvoicesCannotBeDeleted() {
        let invoice = InvoiceBuilder.createInvoice(client: client, bill: [entry(dev, minutes: 60)], cover: [], grouping: .task,
                                                   fixedLines: [], settings: settings, context: context)
        InvoiceBuilder.setStatus(.sent, on: invoice)
        InvoiceBuilder.deleteDraft(invoice, settings: settings, context: context)
        #expect(invoice.entries.count == 1)
        #expect(invoice.sentAt != nil)
    }

    @Test func rateChangesDontAlterExistingInvoices() {
        let invoice = InvoiceBuilder.createInvoice(client: client, bill: [entry(dev, minutes: 60)], cover: [], grouping: .task,
                                                   fixedLines: [], settings: settings, context: context)
        client.defaultRate = 999
        InvoiceBuilder.recalculate(invoice)
        #expect(invoice.subtotal == 150)
    }

    @Test func clientEditsDontAlterSnapshot() {
        client.billingName = "Acme Ltd"
        let invoice = InvoiceBuilder.createInvoice(client: client, bill: [], cover: [], grouping: .task,
                                                   fixedLines: [], settings: settings, context: context)
        client.billingName = "Renamed"
        #expect(invoice.clientBillingName == "Acme Ltd")
    }

    @Test func dueTwentiethOfFollowingMonth() {
        let cal = Calendar.current
        let issue = cal.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        #expect(settings.dueDate(forIssue: issue) == cal.date(from: DateComponents(year: 2026, month: 10, day: 20)))
        let december = cal.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        #expect(settings.dueDate(forIssue: december) == cal.date(from: DateComponents(year: 2027, month: 1, day: 20)))
        settings.dueDateRule = .days
        #expect(settings.dueDate(forIssue: issue) == cal.date(byAdding: .day, value: 14, to: issue))
    }

    @Test func billsExactMinutesNotDecimalHours() {
        // 0:53 and 0:07 at $150 — Harvest would have rounded to 0.88 h / 0.12 h first.
        let invoice = InvoiceBuilder.createInvoice(
            client: client, bill: [entry(dev, minutes: 53), entry(dev, minutes: 7)], cover: [],
            grouping: .entry, fixedLines: [], settings: settings, context: context)
        #expect(invoice.sortedLines.map(\.amount) == [Decimal(string: "132.5")!, Decimal(string: "17.5")!])
        #expect(invoice.sortedLines.map { HoursFormat.clock($0.quantity ?? 0) } == ["0:53", "0:07"])
        #expect(HoursFormat.long(invoice.totalHours) == "1h")
        // Seconds are ignored, matching what the timesheet shows.
        #expect(InvoiceBuilder.billableMinutes(entry(dev, minutes: 41.9), roundingMinutes: 0) == 41)
        #expect(InvoiceBuilder.amount(hours: Decimal(41) / 60, rate: 150) == Decimal(string: "102.5")!)
        settings.taxRate = Decimal(string: "0.15")!
        let totals = Money.round(Decimal(string: "4012.50")! * settings.taxRate)
        #expect(totals == Decimal(string: "601.88")!)
    }

    @Test func notesFilledFromSettings() {
        settings.gstNumber = "123-456-789"
        settings.bankAccount = "Name: Test\nNumber: 12-3456"
        let invoice = InvoiceBuilder.createInvoice(client: client, bill: [], cover: [], grouping: .task,
                                                   fixedLines: [], settings: settings, context: context)
        #expect(invoice.notes.contains("GST Number: 123-456-789"))
        #expect(invoice.notes.contains("Number: 12-3456"))
    }

    @Test func writeOffAndUndo() {
        let e = entry(dev, minutes: 60)
        InvoiceBuilder.writeOff([e], reason: "Goodwill")
        #expect(e.billingState == .writtenOff)
        #expect(e.writeOffReason == "Goodwill")
        #expect(unbilledTotal() == 0)
        InvoiceBuilder.undoWriteOff([e])
        #expect(e.billingState == .unbilled)
        #expect(unbilledTotal() == 150)
    }

    @Test func suggestedActions() {
        #expect(EntryAction.suggested(for: entry(dev, minutes: 1)) == .bill)
        #expect(EntryAction.suggested(for: entry(fixedTask, minutes: 1)) == .cover)
        let nb = entry(dev, minutes: 1)
        nb.isBillable = false
        #expect(EntryAction.suggested(for: nb) == .skip)
    }
}
