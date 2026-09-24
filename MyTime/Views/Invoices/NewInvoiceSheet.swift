import SwiftData
import SwiftUI

/// Which unbilled hours go on the invoice.
enum HoursScope: String, CaseIterable, Identifiable {
    case all, period, none
    var id: Self { self }
}

enum HoursPeriod: String, CaseIterable, Identifiable {
    case thisMonth, lastMonth, thisWeek, lastWeek, thisYear, lastYear, custom
    var id: Self { self }

    func title(now: Date = .now) -> String {
        let cal = Calendar.current
        let month = { (d: Date) in d.formatted(.dateTime.month(.wide)) }
        let year = { (d: Date) in d.formatted(.dateTime.year()) }
        switch self {
        case .thisMonth: return "This month (\(month(now)))"
        case .lastMonth: return "Last month (\(month(cal.date(byAdding: .month, value: -1, to: now) ?? now)))"
        case .thisWeek: return "This week"
        case .lastWeek: return "Last week"
        case .thisYear: return "This year (\(year(now)))"
        case .lastYear: return "Last year (\(year(cal.date(byAdding: .year, value: -1, to: now) ?? now)))"
        case .custom: return "Custom range…"
        }
    }

    /// Inclusive start-of-day bounds.
    func bounds(now: Date = .now, customFrom: Date, customTo: Date) -> (Date, Date) {
        let cal = Calendar.current
        func interval(_ unit: Calendar.Component, offset: Int) -> (Date, Date) {
            let base = cal.date(byAdding: unit, value: offset, to: now) ?? now
            let start: Date
            if unit == .weekOfYear { start = Week.start(of: base) } else { start = cal.dateInterval(of: unit, for: base)?.start ?? base }
            let end = cal.date(byAdding: unit, value: 1, to: start).flatMap { cal.date(byAdding: .day, value: -1, to: $0) } ?? start
            return (start, end)
        }
        switch self {
        case .thisMonth: return interval(.month, offset: 0)
        case .lastMonth: return interval(.month, offset: -1)
        case .thisWeek: return interval(.weekOfYear, offset: 0)
        case .lastWeek: return interval(.weekOfYear, offset: -1)
        case .thisYear: return interval(.year, offset: 0)
        case .lastYear: return interval(.year, offset: -1)
        case .custom: return (cal.startOfDay(for: customFrom), cal.startOfDay(for: customTo))
        }
    }
}

struct NewInvoiceSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var onCreate: (Invoice) -> Void

    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name) private var clients: [Client]
    @Query private var unbilled: [TimeEntry]
    @Query(sort: \Invoice.issueDate, order: .reverse) private var invoices: [Invoice]

    private enum Step { case start, configure }
    private enum Source { case tracked, scratch }

    @State private var step = Step.start
    @State private var source = Source.tracked
    @State private var client: Client?

    @State private var selectedProjects: Set<PersistentIdentifier> = []
    @State private var scope = HoursScope.all
    @State private var period = HoursPeriod.thisMonth
    @State private var customFrom = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customTo = Date.now
    @AppStorage("invoiceGrouping") private var grouping: LineGrouping = .projectTask
    @AppStorage("invoiceLineDetails") private var detailsRaw = LineDetails.standard.rawValue

    @State private var actions: [PersistentIdentifier: EntryAction] = [:]
    @State private var showNonBillable = false
    @State private var showEntries = false
    @State private var feeIncluded: Set<PersistentIdentifier> = []
    @State private var feeLines: [PersistentIdentifier: FixedLineInput] = [:]
    @State private var extraLines: [FixedLineInput] = []

    init(onCreate: @escaping (Invoice) -> Void) {
        self.onCreate = onCreate
        let raw = BillingState.unbilled.rawValue
        // Unbilled and not currently running.
        _unbilled = Query(filter: #Predicate<TimeEntry> { $0.billingStateRaw == raw && ($0.startedAt == nil || $0.endedAt != nil) },
                          sort: \TimeEntry.date)
    }

    var body: some View {
        Group {
            switch step {
            case .start: startStep
            case .configure: configureStep
            }
        }
        .onAppear(perform: pickDefaultClient)
    }

    // MARK: Step 1 — client and type

    private var startStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("New invoice").font(.title.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Client").font(.headline)
                Picker("Client", selection: $client) {
                    Text("Choose…").tag(Client?.none)
                    ForEach(clients) { client in
                        let amount = uninvoiced(for: client)
                        Text(amount > 0 ? "\(client.name)  —  \(Money.format(amount)) uninvoiced" : client.name)
                            .tag(Optional(client))
                    }
                }
                .labelsHidden()
                .controlSize(.large)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Type").font(.headline)
                HStack(spacing: 12) {
                    ChoiceCard(title: "From tracked time", subtitle: "Auto-fill from unbilled hours",
                               systemImage: "clock", selected: source == .tracked) { source = .tracked }
                    ChoiceCard(title: "From scratch", subtitle: "Add your own line items",
                               systemImage: "pencil", selected: source == .scratch) { source = .scratch }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(source == .tracked ? "Choose Projects" : "Create Invoice") {
                    if source == .tracked { prepareConfigure(); step = .configure } else { createFromScratch() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(client == nil)
            }
        }
        .padding(28)
        .frame(width: 560, height: 380)
    }

    // MARK: Step 2 — projects, hours, display

    private var configureStep: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Avatar(name: client?.name ?? "", size: 34, imageData: client?.logoData)
                Text("New invoice for \(client?.name ?? "")").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    projectsSection
                    hoursSection
                    if !selectedFixedFeeProjects.isEmpty { fixedFeeSection }
                    extraLinesSection
                    previewSection
                }
                .padding(28)
            }

            Divider()

            HStack(spacing: 12) {
                Button("Back") { step = .start }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Subtotal \(Money.format(subtotal))").font(.headline).monospacedDigit()
                    Text("\(HoursFormat.long(billedHours)) billed" + (coverEntries.isEmpty ? "" : ", \(coverEntries.count) covered"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Create Invoice", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canCreate)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(width: 920, height: 760)
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What projects would you like to invoice?").font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                HStack {
                    Text("Select").foregroundStyle(.secondary)
                    Button("All") { selectedProjects = Set(candidateProjects.map(\.persistentModelID)) }.buttonStyle(.link)
                    Text("/").foregroundStyle(.secondary)
                    Button("None") { selectedProjects = [] }.buttonStyle(.link)
                    Spacer()
                    Text("Uninvoiced").frame(width: 150, alignment: .trailing)
                    Text("Last invoice").frame(width: 210, alignment: .leading).padding(.leading, 20)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if candidateProjects.isEmpty {
                    Divider()
                    Text("No unbilled time for \(client?.name ?? "this client").")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
                ForEach(candidateProjects) { project in
                    Divider()
                    projectRow(project)
                }
            }
            .card(padding: 0, cornerRadius: 12)
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let id = project.persistentModelID
        let entries = unbilledEntries(in: project)
        let last = lastInvoice(for: project)
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { selectedProjects.contains(id) },
                set: { if $0 { selectedProjects.insert(id) } else { selectedProjects.remove(id) } }
            )) {
                HStack(spacing: 6) {
                    Text(project.name)
                    Tag(text: project.billingType == .hourly ? "Time & Materials" : "Fixed fee",
                        color: project.billingType == .hourly ? .blue : .purple)
                    if project.isArchived { Tag(text: "Archived", color: .orange) }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if project.billingType == .hourly {
                    Text(Money.format(BillingSummary.uninvoicedAmount(entries)))
                }
                Text(DurationFormat.short(BillingSummary.totalSeconds(entries)) + " h")
                    .font(project.billingType == .hourly ? .caption : .body)
                    .foregroundStyle(project.billingType == .hourly ? .secondary : .primary)
            }
            .monospacedDigit()
            .frame(width: 150, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                if let last {
                    Text("\(DateText.short(last.issueDate)) • \(Money.format(last.total)) • \(last.number)")
                    if let span = entrySpan(last) {
                        Text(span).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("N/A").foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .frame(width: 210, alignment: .leading)
            .padding(.leading, 20)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(selectedProjects.contains(id) ? 1 : 0.6)
    }

    private var hoursSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What hours would you like to invoice?").font(.title3.weight(.semibold))
            Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 20) {
                GridRow {
                    Text("Billable hours").font(.headline).frame(width: 150, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        RadioRow(selected: scope == .all) { scope = .all } label: {
                            Text("All uninvoiced billable hours")
                        }
                        RadioRow(selected: scope == .period) { scope = .period } label: {
                            Text("Include uninvoiced billable hours from")
                        } trailing: {
                            Picker("Period", selection: Binding(get: { period }, set: { period = $0; scope = .period })) {
                                ForEach(HoursPeriod.allCases) { Text($0.title()).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        }
                        RadioRow(selected: scope == .none) { scope = .none } label: {
                            Text("Do not include any hours")
                        }
                        if scope == .period, period == .custom {
                            HStack {
                                DatePicker("From", selection: $customFrom, displayedComponents: .date)
                                DatePicker("to", selection: $customTo, displayedComponents: .date)
                            }
                            .fixedSize()
                            .padding(.leading, 20)
                        }
                    }
                }
                GridRow {
                    Text("How to display hours").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(LineGrouping.allCases) { option in
                            RadioRow(selected: grouping == option) { grouping = option } label: {
                                Text("\(Text(option.rawValue).bold()): \(option.summary)")
                            }
                        }
                    }
                }
                GridRow {
                    Text("Time entry details").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Include the following info for each line item:").foregroundStyle(.secondary)
                        HStack(spacing: 18) {
                            detailToggle("Project", .project, enabled: grouping.usesProjectAndTaskOptions)
                            detailToggle("Task", .task, enabled: grouping.usesProjectAndTaskOptions)
                            detailToggle("Date", .date)
                            detailToggle("Notes", .notes)
                        }
                    }
                }
            }
            .card(padding: 20)

            reviewEntries
        }
    }

    private func detailToggle(_ title: String, _ option: LineDetails, enabled: Bool = true) -> some View {
        Toggle(title, isOn: Binding(
            get: { LineDetails(rawValue: detailsRaw).contains(option) },
            set: { on in
                var set = LineDetails(rawValue: detailsRaw)
                if on { set.insert(option) } else { set.remove(option) }
                detailsRaw = set.rawValue
            }
        ))
        .toggleStyle(.checkbox)
        .disabled(!enabled)
        .help(enabled ? "" : "Project and task are already shown with this layout")
    }

    private var reviewEntries: some View {
        DisclosureGroup(isExpanded: $showEntries) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Bill charges hourly. Cover closes the time against this invoice with no hourly charge. Skip leaves it unbilled.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Show non-billable", isOn: $showNonBillable).toggleStyle(.checkbox).font(.caption)
                    Menu("Set all") {
                        ForEach(EntryAction.allCases) { choice in
                            Button(choice.rawValue) { reviewable.forEach { actions[$0.persistentModelID] = choice } }
                        }
                    }
                    .fixedSize()
                }
                if reviewable.isEmpty {
                    Text("No entries match.").foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(reviewable) { entry in
                    HStack(alignment: .top) {
                        Text(DateText.short(entry.date)).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 84, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.task?.shortPath ?? "")
                            if !entry.note.isEmpty {
                                Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(DurationFormat.short(entry.liveDuration())).monospacedDigit()
                        Picker("Action", selection: Binding(
                            get: { action(entry) },
                            set: { actions[entry.persistentModelID] = $0 }
                        )) {
                            ForEach(EntryAction.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Review \(reviewable.count) entr\(reviewable.count == 1 ? "y" : "ies")").font(.headline)
        }
        .card(padding: 16)
    }

    private var fixedFeeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fixed-fee projects").font(.title3.weight(.semibold))
            Text("Their hours are closed against this invoice without an hourly charge. Add the agreed fee as a line if it's due now.")
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(selectedFixedFeeProjects) { project in
                    let id = project.persistentModelID
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { feeIncluded.contains(id) },
                            set: { if $0 { feeIncluded.insert(id) } else { feeIncluded.remove(id) } }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        TextField("Description", text: feeBinding(project).description)
                            .textFieldStyle(.roundedBorder)
                        DecimalField(title: "Amount", value: feeBinding(project).amount)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 110)
                        Text("\(DurationFormat.short(BillingSummary.totalSeconds(coverEntries.filter { $0.task?.project?.persistentModelID == id }))) h covered")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 100, alignment: .trailing)
                    }
                    .opacity(feeIncluded.contains(id) ? 1 : 0.6)
                }
            }
            .card(padding: 16)
        }
    }

    private var extraLinesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Additional lines").font(.title3.weight(.semibold))
                Spacer()
                Button { extraLines.append(FixedLineInput(description: "", amount: 0)) } label: {
                    Label("Add line", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            if extraLines.isEmpty {
                Text("Agreed fees, expenses or anything else not from the timesheet.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach($extraLines) { $line in
                        HStack(spacing: 12) {
                            TextField("Description", text: $line.description).textFieldStyle(.roundedBorder)
                            DecimalField(title: "Amount", value: $line.amount)
                                .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 110)
                            Button { extraLines.removeAll { $0.id == line.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .card(padding: 16)
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                if previewLines.isEmpty && fixedLines.isEmpty {
                    Text("Nothing to invoice yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(previewLines.enumerated()), id: \.offset) { index, line in
                    if !line.groupTitle.isEmpty, index == 0 || previewLines[index - 1].groupTitle != line.groupTitle {
                        Text(line.groupTitle).font(.headline).foregroundStyle(.tint).padding(.top, index == 0 ? 0 : 6)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.description)
                            if !line.details.isEmpty {
                                Text(line.details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text("\(HoursFormat.clock(line.hours)) × \(Money.format(line.rate))").foregroundStyle(.secondary)
                        Text(Money.format(line.amount)).bold().frame(width: 100, alignment: .trailing)
                    }
                    .monospacedDigit()
                    .padding(.leading, line.groupTitle.isEmpty ? 0 : 12)
                }
                ForEach(fixedLines) { line in
                    HStack {
                        Text(line.description.isEmpty ? "Untitled line" : line.description)
                        Spacer()
                        Text(Money.format(Money.round(line.amount))).bold().monospacedDigit().frame(width: 100, alignment: .trailing)
                    }
                }
            }
            .card(padding: 20)
        }
    }

    // MARK: Data

    private func belongsToClient(_ entry: TimeEntry) -> Bool {
        entry.task?.project?.client?.persistentModelID == client?.persistentModelID
    }

    private var clientEntries: [TimeEntry] { client == nil ? [] : unbilled.filter(belongsToClient) }

    private func unbilledEntries(in project: Project) -> [TimeEntry] {
        clientEntries.filter { $0.task?.project?.persistentModelID == project.persistentModelID }
    }

    private func uninvoiced(for client: Client) -> Decimal {
        BillingSummary.uninvoicedAmount(unbilled.filter { $0.task?.project?.client?.persistentModelID == client.persistentModelID })
    }

    /// Projects with any unbilled time, hourly first.
    private var candidateProjects: [Project] {
        var seen = Set<PersistentIdentifier>()
        return clientEntries.compactMap(\.task?.project)
            .filter { seen.insert($0.persistentModelID).inserted }
            .sorted {
                ($0.isArchived ? 1 : 0, $0.billingType == .hourly ? 0 : 1, $0.name)
                    < ($1.isArchived ? 1 : 0, $1.billingType == .hourly ? 0 : 1, $1.name)
            }
    }

    private func lastInvoice(for project: Project) -> Invoice? {
        invoices.first { invoice in
            invoice.entries.contains { $0.task?.project?.persistentModelID == project.persistentModelID }
        }
    }

    private func entrySpan(_ invoice: Invoice) -> String? {
        let dates = invoice.entries.map(\.date)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return "\(DateText.short(first)) to \(DateText.short(last))"
    }

    /// Unbilled entries in the chosen projects and hours scope.
    private var candidates: [TimeEntry] {
        guard scope != .none else { return [] }
        let (start, end) = period.bounds(customFrom: customFrom, customTo: customTo)
        return clientEntries.filter { entry in
            guard let project = entry.task?.project, selectedProjects.contains(project.persistentModelID) else { return false }
            return scope == .all || (entry.date >= start && entry.date <= end)
        }
    }

    private var reviewable: [TimeEntry] {
        candidates.filter { showNonBillable || EntryAction.suggested(for: $0) != .skip }
    }

    private func action(_ entry: TimeEntry) -> EntryAction {
        actions[entry.persistentModelID] ?? EntryAction.suggested(for: entry)
    }

    private var billEntries: [TimeEntry] { candidates.filter { action($0) == .bill } }
    private var coverEntries: [TimeEntry] { candidates.filter { action($0) == .cover } }

    private var billedHours: Decimal { previewLines.reduce(0) { $0 + $1.hours } }

    private var selectedFixedFeeProjects: [Project] {
        candidateProjects.filter { $0.billingType == .fixedFee && selectedProjects.contains($0.persistentModelID) }
    }

    private func defaultFeeLine(_ project: Project) -> FixedLineInput {
        FixedLineInput(description: "\(project.name) - agreed fee", amount: project.fixedFee ?? 0)
    }

    private func feeBinding(_ project: Project) -> Binding<FixedLineInput> {
        let id = project.persistentModelID
        return Binding(
            get: { feeLines[id] ?? defaultFeeLine(project) },
            set: { feeLines[id] = $0 }
        )
    }

    private var fixedLines: [FixedLineInput] {
        selectedFixedFeeProjects
            .filter { feeIncluded.contains($0.persistentModelID) }
            .map { feeLines[$0.persistentModelID] ?? defaultFeeLine($0) }
        + extraLines.filter { $0.amount != 0 || !$0.description.isEmpty }
    }

    private var settings: BusinessSettings { BusinessSettings.current(in: context) }

    private var previewLines: [LineSpec] {
        InvoiceBuilder.hourlyLines(for: billEntries, grouping: grouping, roundingMinutes: settings.roundingMinutes,
                                   include: LineDetails(rawValue: detailsRaw))
    }

    private var subtotal: Decimal {
        previewLines.reduce(0) { $0 + $1.amount } + fixedLines.reduce(0) { $0 + Money.round($1.amount) }
    }

    private var canCreate: Bool {
        client != nil && (!previewLines.isEmpty || !coverEntries.isEmpty || fixedLines.contains { $0.amount != 0 })
    }

    // MARK: Actions

    private func pickDefaultClient() {
        guard client == nil else { return }
        // Default to the client with the most unbilled billable time.
        let counts = Dictionary(grouping: unbilled.filter { EntryAction.suggested(for: $0) != .skip }) {
            $0.task?.project?.client?.persistentModelID
        }
        client = clients.max { (counts[$0.persistentModelID]?.count ?? 0) < (counts[$1.persistentModelID]?.count ?? 0) }
    }

    private func prepareConfigure() {
        actions = [:]
        feeLines = [:]
        extraLines = []
        selectedProjects = Set(candidateProjects.map(\.persistentModelID))
        // Suggest the agreed fee for fixed-fee projects that haven't been invoiced yet.
        feeIncluded = Set(candidateProjects
            .filter { $0.billingType == .fixedFee && ($0.fixedFee ?? 0) > 0 && lastInvoice(for: $0) == nil }
            .map(\.persistentModelID))
    }

    private func createFromScratch() {
        guard let client else { return }
        let invoice = InvoiceBuilder.createInvoice(
            client: client, bill: [], cover: [], grouping: grouping,
            fixedLines: [FixedLineInput(description: "", amount: 0)],
            settings: settings, context: context
        )
        onCreate(invoice)
        dismiss()
    }

    private func create() {
        guard let client else { return }
        let invoice = InvoiceBuilder.createInvoice(
            client: client,
            bill: billEntries,
            cover: coverEntries,
            grouping: grouping,
            include: LineDetails(rawValue: detailsRaw),
            fixedLines: fixedLines,
            settings: settings,
            context: context
        )
        onCreate(invoice)
        dismiss()
    }
}

/// Large selectable option, like Harvest's "From tracked time" / "From scratch".
private struct ChoiceCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .card(padding: 14, cornerRadius: 12, tint: selected ? .accentColor : nil, highlighted: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A single radio option whose label can be followed by another control (e.g. a period menu).
private struct RadioRow<Label: View, Trailing: View>: View {
    let selected: Bool
    var action: () -> Void
    @ViewBuilder var label: Label
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: selected ? "circle.inset.filled" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing
        }
    }
}

extension RadioRow where Trailing == EmptyView {
    init(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.init(selected: selected, action: action, label: label, trailing: { EmptyView() })
    }
}
