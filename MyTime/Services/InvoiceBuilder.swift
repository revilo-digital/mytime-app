import Foundation
import SwiftData

/// How billed entries are turned into hourly invoice lines.
enum LineGrouping: String, CaseIterable, Identifiable {
    /// Project headings, one line per task with deduplicated notes underneath.
    case projectTask = "By project, then task"
    case entry = "Every entry"
    case task = "By task"
    case project = "By project"
    case single = "Single line"
    var id: Self { self }

    var summary: String {
        switch self {
        case .projectTask: "Project headings, one line per task with its notes underneath"
        case .entry: "Display each time entry as its own line"
        case .task: "Combine all hours for one task into one line"
        case .project: "Combine all hours for one project into one line"
        case .single: "Combine all hours into one line"
        }
    }

    /// Whether the project / task detail options change anything for this grouping.
    var usesProjectAndTaskOptions: Bool { self == .entry || self == .task }
}

/// Extra information shown on each hourly line.
struct LineDetails: OptionSet, Hashable {
    let rawValue: Int
    static let project = LineDetails(rawValue: 1 << 0)
    static let task = LineDetails(rawValue: 1 << 1)
    static let date = LineDetails(rawValue: 1 << 2)
    static let notes = LineDetails(rawValue: 1 << 3)
    static let standard: LineDetails = [.project, .task, .notes]
}

/// What to do with each unbilled entry when creating an invoice.
enum EntryAction: String, CaseIterable, Identifiable {
    /// Charge hourly — becomes invoice lines.
    case bill = "Bill"
    /// Close against this invoice without charging hourly (fixed-fee work).
    case cover = "Cover"
    /// Leave unbilled.
    case skip = "Skip"
    var id: Self { self }

    /// Sensible default: hourly billable time is billed, fixed-fee time is covered.
    static func suggested(for entry: TimeEntry) -> EntryAction {
        guard entry.isBillable, RateResolver.isBillable(entry.task) else { return .skip }
        return entry.task?.project?.billingType == .fixedFee ? .cover : .bill
    }
}

struct FixedLineInput: Identifiable, Equatable {
    var id = UUID()
    var description: String
    var amount: Decimal
}

struct LineSpec: Equatable {
    var description: String
    var hours: Decimal
    var rate: Decimal
    var amount: Decimal
    var groupTitle: String = ""
    var details: String = ""
}

@MainActor
enum InvoiceBuilder {
    // MARK: Hours and lines

    /// Billable minutes for one entry: whole minutes as shown on the timesheet,
    /// rounded up to the billing increment if one is set.
    static func billableMinutes(_ entry: TimeEntry, roundingMinutes: Int) -> Int {
        let minutes = Int(entry.liveDuration().rounded(.down)) / 60
        guard roundingMinutes > 0 else { return minutes }
        return Int((Double(minutes) / Double(roundingMinutes)).rounded(.up)) * roundingMinutes
    }

    /// Billable time for one entry as decimal hours (exact minutes ÷ 60).
    static func billableHours(_ entry: TimeEntry, roundingMinutes: Int) -> Decimal {
        Decimal(billableMinutes(entry, roundingMinutes: roundingMinutes)) / 60
    }

    /// Money for a time quantity. Snaps to whole minutes and multiplies before dividing
    /// so 0:41 at $150 is exactly $102.50.
    static func amount(hours: Decimal, rate: Decimal) -> Decimal {
        Money.round(Decimal(HoursFormat.minutes(hours)) * rate / 60)
    }

    static func hourlyLines(for entries: [TimeEntry], grouping: LineGrouping, roundingMinutes: Int,
                            include: LineDetails = .standard) -> [LineSpec] {
        struct Key: Hashable { var group: String; var label: String; var rate: Decimal; var index: Int }

        func key(_ entry: TimeEntry, index: Int) -> Key {
            let project = entry.task?.project?.name ?? "Time"
            let task = entry.task?.name ?? ""
            var parts: [String] = []
            if include.contains(.project) { parts.append(project) }
            if include.contains(.task), !task.isEmpty { parts.append(task) }
            let rate = RateResolver.rate(for: entry.task)
            switch grouping {
            case .projectTask: return Key(group: project, label: task.isEmpty ? project : task, rate: rate, index: 0)
            case .task:
                if !include.contains(.task), !task.isEmpty, parts.isEmpty { parts.append(task) }
                return Key(group: "", label: parts.isEmpty ? project : parts.joined(separator: " - "), rate: rate, index: 0)
            case .project: return Key(group: "", label: project, rate: rate, index: 0)
            case .single: return Key(group: "", label: "Professional services", rate: rate, index: 0)
            case .entry:
                if include.contains(.date) { parts.append(DateText.short(entry.date)) }
                var label = parts.isEmpty ? "Time" : parts.joined(separator: " - ")
                if include.contains(.notes), !entry.note.isEmpty { label += ": \(entry.note)" }
                return Key(group: "", label: label, rate: rate, index: index) // keep entries distinct
            }
        }

        // Grouped by project, then chronological.
        let sorted = entries.sorted {
            let (p0, p1) = ($0.task?.project?.name ?? "", $1.task?.project?.name ?? "")
            if p0 != p1 { return p0.localizedStandardCompare(p1) == .orderedAscending }
            return ($0.date, $0.createdAt) < ($1.date, $1.createdAt)
        }

        var order: [Key] = []
        var minutes: [Key: Int] = [:]
        var notes: [Key: [String]] = [:]
        var dates: [Key: (Date, Date)] = [:]
        for (index, entry) in sorted.enumerated() {
            let k = key(entry, index: index)
            if minutes[k] == nil { order.append(k) }
            let span = dates[k] ?? (entry.date, entry.date)
            dates[k] = (min(span.0, entry.date), max(span.1, entry.date))
            minutes[k, default: 0] += billableMinutes(entry, roundingMinutes: roundingMinutes)
            let note = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty, notes[k, default: []].contains(where: { $0.caseInsensitiveCompare(note) == .orderedSame }) == false {
                notes[k, default: []].append(note)
            }
        }

        if grouping == .projectTask {
            // Within each project, order tasks by name so "1. Briefing" precedes "4. Technical".
            let projects = order.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            order = projects.flatMap { project in
                order.filter { $0.group == project }
                    .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            }
        }

        return order.map { k in
            let qty = Decimal(minutes[k] ?? 0) / 60
            var details: [String] = []
            if grouping != .entry {
                if include.contains(.date), let (first, last) = dates[k] {
                    details.append(first == last ? DateText.short(first) : "\(DateText.short(first)) – \(DateText.short(last))")
                }
                if include.contains(.notes) { details += notes[k] ?? [] }
            }
            return LineSpec(
                description: k.label, hours: qty, rate: k.rate, amount: amount(hours: qty, rate: k.rate),
                groupTitle: k.group,
                details: details.joined(separator: " · ")
            )
        }
    }

    // MARK: Create / recalculate / delete

    static func createInvoice(
        client: Client,
        bill: [TimeEntry],
        cover: [TimeEntry],
        grouping: LineGrouping,
        include: LineDetails = .standard,
        fixedLines: [FixedLineInput],
        issueDate: Date = .now,
        settings: BusinessSettings,
        context: ModelContext
    ) -> Invoice {
        let invoice = Invoice(client: client, issueDate: issueDate,
                              dueDate: settings.dueDate(forIssue: issueDate), taxRate: settings.taxRate)
        invoice.subject = settings.defaultSubject
        invoice.number = "\(settings.invoicePrefix)\(settings.nextInvoiceNumber)"
        settings.nextInvoiceNumber += 1
        invoice.business = settings.snapshot
        invoice.notes = settings.fill(settings.defaultInvoiceNotes)
        context.insert(invoice)

        var order = 0
        for spec in hourlyLines(for: bill, grouping: grouping, roundingMinutes: settings.roundingMinutes, include: include) {
            let line = InvoiceLine(kind: .hourly, description: spec.description, quantity: spec.hours,
                                   unitPrice: spec.rate, amount: spec.amount, sortOrder: order,
                                   groupTitle: spec.groupTitle, details: spec.details)
            line.invoice = invoice
            context.insert(line)
            order += 1
        }
        for fixed in fixedLines {
            let line = InvoiceLine(kind: .fixed, description: fixed.description, quantity: nil,
                                   unitPrice: fixed.amount, amount: Money.round(fixed.amount), sortOrder: order)
            line.invoice = invoice
            context.insert(line)
            order += 1
        }

        for entry in bill { attach(entry, to: invoice, as: .billed) }
        for entry in cover { attach(entry, to: invoice, as: .covered) }

        recalculate(invoice)
        try? context.save()
        return invoice
    }

    private static func attach(_ entry: TimeEntry, to invoice: Invoice, as state: BillingState) {
        entry.invoice = invoice
        entry.billingState = state
    }

    /// Recomputes line amounts, subtotal, GST and total.
    static func recalculate(_ invoice: Invoice) {
        for line in invoice.lines where line.kind == .hourly {
            line.amount = amount(hours: line.quantity ?? 0, rate: line.unitPrice)
        }
        for line in invoice.lines where line.kind == .fixed {
            line.amount = Money.round(line.unitPrice)
        }
        invoice.subtotal = invoice.lines.reduce(0) { $0 + $1.amount }
        invoice.taxAmount = Money.round(invoice.subtotal * invoice.taxRate)
        invoice.total = invoice.subtotal + invoice.taxAmount
    }

    /// Deletes a draft and returns its entries to unbilled. If it held the latest
    /// number, the counter rolls back so numbers stay sequential.
    static func deleteDraft(_ invoice: Invoice, settings: BusinessSettings, context: ModelContext) {
        guard invoice.status == .draft else { return }
        for entry in invoice.entries {
            entry.invoice = nil
            entry.billingState = .unbilled
        }
        if invoice.number == "\(settings.invoicePrefix)\(settings.nextInvoiceNumber - 1)" {
            settings.nextInvoiceNumber -= 1
        }
        context.delete(invoice)
        try? context.save()
    }

    static func setStatus(_ status: InvoiceStatus, on invoice: Invoice, at now: Date = .now) {
        invoice.status = status
        switch status {
        case .draft:
            invoice.sentAt = nil
            invoice.paidAt = nil
        case .sent:
            if invoice.sentAt == nil { invoice.sentAt = now }
            invoice.paidAt = nil
        case .paid:
            if invoice.sentAt == nil { invoice.sentAt = now }
            invoice.paidAt = now
        }
    }

    // MARK: Write-off

    static func writeOff(_ entries: [TimeEntry], reason: String) {
        for entry in entries where entry.billingState == .unbilled && !entry.isRunning {
            entry.billingState = .writtenOff
            entry.writeOffReason = reason.isEmpty ? nil : reason
        }
    }

    static func undoWriteOff(_ entries: [TimeEntry]) {
        for entry in entries where entry.billingState == .writtenOff {
            entry.billingState = .unbilled
            entry.writeOffReason = nil
        }
    }
}
