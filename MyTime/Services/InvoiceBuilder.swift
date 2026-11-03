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
    /// The project an agreed fee is for, so it lands under that project's end client.
    var project: Project?
}

/// One invoice line before it's saved. Fixed lines have no hours; `rate` holds their amount.
struct LineSpec: Equatable {
    var description: String
    var hours: Decimal
    var rate: Decimal
    var amount: Decimal
    var groupTitle: String = ""
    var details: String = ""
    var sectionTitle: String = ""
    var kind: InvoiceLineKind = .hourly
    var project: Project?
}

@MainActor
enum InvoiceBuilder {
    // MARK: Hours and lines

    /// Billable minutes for one entry: whole minutes as shown on the timesheet,
    /// rounded up to the billing increment if one is set.
    static func billableMinutes(_ entry: TimeEntry, roundingMinutes: Int) -> Int {
        let minutes = BillingSummary.wholeMinutes(entry)
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
        BillingSummary.amount(minutes: HoursFormat.minutes(hours), rate: rate)
    }

    /// Where a project's lines go on an invoice with end-client sections: the client's own work
    /// under the client's name first (rank 0), then each end client A–Z (rank 1).
    static func section(of project: Project?) -> (rank: Int, title: String) {
        if let endClient = project?.endClient { return (1, endClient.name) }
        return (0, project?.client?.name ?? "")
    }

    /// With `sections`, every line gets a section title (see `section(of:)`) and project names
    /// drop their end client, which the section heading shows instead.
    static func hourlyLines(for entries: [TimeEntry], grouping: LineGrouping, roundingMinutes: Int,
                            include: LineDetails = .standard, sections: Bool = false) -> [LineSpec] {
        struct Key: Hashable { var section: String; var group: String; var label: String; var rate: Decimal; var index: Int }

        func projectName(_ entry: TimeEntry) -> String {
            (sections ? entry.task?.project?.name : entry.task?.project?.qualifiedName) ?? "Time"
        }

        func key(_ entry: TimeEntry, index: Int) -> Key {
            let section = sections ? Self.section(of: entry.task?.project).title : ""
            let project = projectName(entry)
            let task = entry.task?.name ?? ""
            var parts: [String] = []
            if include.contains(.project) { parts.append(project) }
            if include.contains(.task), !task.isEmpty { parts.append(task) }
            let rate = RateResolver.rate(for: entry.task)
            switch grouping {
            case .projectTask: return Key(section: section, group: project, label: task.isEmpty ? project : task, rate: rate, index: 0)
            case .task:
                if !include.contains(.task), !task.isEmpty, parts.isEmpty { parts.append(task) }
                return Key(section: section, group: "", label: parts.isEmpty ? project : parts.joined(separator: " - "), rate: rate, index: 0)
            case .project: return Key(section: section, group: "", label: project, rate: rate, index: 0)
            case .single: return Key(section: section, group: "", label: "Professional services", rate: rate, index: 0)
            case .entry:
                if include.contains(.date) { parts.append(DateText.short(entry.date)) }
                var label = parts.isEmpty ? "Time" : parts.joined(separator: " - ")
                if include.contains(.notes), !entry.note.isEmpty { label += ": \(entry.note)" }
                return Key(section: section, group: "", label: label, rate: rate, index: index) // keep entries distinct
            }
        }

        // Grouped by section, then project, then chronological.
        let sorted = entries.sorted {
            if sections {
                let (s0, s1) = (Self.section(of: $0.task?.project), Self.section(of: $1.task?.project))
                if s0.rank != s1.rank { return s0.rank < s1.rank }
                if s0.title != s1.title { return s0.title.localizedStandardCompare(s1.title) == .orderedAscending }
            }
            let (p0, p1) = (projectName($0), projectName($1))
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
            // Projects are told apart by section too: two end clients can each have a "Website".
            let projects = order.map { [$0.section, $0.group] }.reduce(into: [[String]]()) { if !$0.contains($1) { $0.append($1) } }
            order = projects.flatMap { project in
                order.filter { [$0.section, $0.group] == project }
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
                details: details.joined(separator: " · "),
                sectionTitle: k.section
            )
        }
    }

    /// Every line for a new invoice, in order. With `bySection`, if any of the work is for an end
    /// client, lines go under a section per end client (see `section(of:)`): each section's fees
    /// straight under its heading, then its hourly lines, and fixed lines without a project last.
    static func invoiceLines(bill: [TimeEntry], fixed: [FixedLineInput], grouping: LineGrouping, roundingMinutes: Int,
                             include: LineDetails = .standard, bySection: Bool = false) -> [LineSpec] {
        let projects = bill.compactMap(\.task?.project) + fixed.compactMap(\.project)
        let sectioned = bySection && projects.contains { $0.endClient != nil }
        let hourly = hourlyLines(for: bill, grouping: grouping, roundingMinutes: roundingMinutes,
                                 include: include, sections: sectioned)
        let fees = fixed.map { line in
            LineSpec(description: line.description, hours: 0, rate: line.amount, amount: Money.round(line.amount),
                     sectionTitle: sectioned ? line.project.map { Self.section(of: $0).title } ?? "" : "", kind: .fixed,
                     project: line.project)
        }
        guard sectioned else { return hourly + fees }

        var rank = ["": 2]
        for project in projects {
            let section = Self.section(of: project)
            rank[section.title] = section.rank
        }
        return (fees + hourly).enumerated().sorted { a, b in
            let (sa, sb) = (a.element.sectionTitle, b.element.sectionTitle)
            let (ra, rb) = (rank[sa] ?? 2, rank[sb] ?? 2)
            if ra != rb { return ra < rb }
            if sa != sb { return sa.localizedStandardCompare(sb) == .orderedAscending }
            return a.offset < b.offset
        }
        .map(\.element)
    }

    // MARK: Choosing projects

    /// Projects that can go on a client's invoice, hourly first: any with unbilled time, plus active
    /// fixed-fee ones, whose agreed fee can be invoiced before any time is tracked.
    static func invoiceableProjects(client: Client, unbilled: [TimeEntry]) -> [Project] {
        let tracked = unbilled.compactMap(\.task?.project)
            .filter { $0.client?.persistentModelID == client.persistentModelID }
        let fixedFee = client.projects.filter { $0.billingType == .fixedFee && !$0.isArchived && $0.isBillable }
        var seen = Set<PersistentIdentifier>()
        return (tracked + fixedFee)
            .filter { seen.insert($0.persistentModelID).inserted }
            .sorted {
                ($0.isArchived ? 1 : 0, $0.billingType == .hourly ? 0 : 1, $0.name)
                    < ($1.isArchived ? 1 : 0, $1.billingType == .hourly ? 0 : 1, $1.name)
            }
    }

    /// The first of `invoices` with this project's time or agreed fee on it.
    static func lastInvoice(for project: Project, in invoices: [Invoice]) -> Invoice? {
        let id = project.persistentModelID
        return invoices.first { invoice in
            invoice.entries.contains { $0.task?.project?.persistentModelID == id }
                || invoice.lines.contains { $0.project?.persistentModelID == id }
        }
    }

    // MARK: Create / recalculate / delete

    static func createInvoice(
        client: Client,
        bill: [TimeEntry],
        cover: [TimeEntry],
        grouping: LineGrouping,
        include: LineDetails = .standard,
        bySection: Bool = false,
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

        let specs = invoiceLines(bill: bill, fixed: fixedLines, grouping: grouping,
                                 roundingMinutes: settings.roundingMinutes, include: include, bySection: bySection)
        for (order, spec) in specs.enumerated() {
            let line = InvoiceLine(kind: spec.kind, description: spec.description,
                                   quantity: spec.kind == .hourly ? spec.hours : nil,
                                   unitPrice: spec.rate, amount: spec.amount, sortOrder: order,
                                   groupTitle: spec.groupTitle, details: spec.details, sectionTitle: spec.sectionTitle)
            line.invoice = invoice
            line.project = spec.project
            context.insert(line)
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
