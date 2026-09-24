import SwiftData
import SwiftUI

enum TimesheetMode: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week"
    var id: Self { self }
}

/// What the entry editor sheet is working on.
enum EntryEditTarget: Identifiable {
    case new(Date, task: TaskType? = nil)
    case existing(TimeEntry)

    var id: String {
        switch self {
        case .new(let date, _): "new-\(date.timeIntervalSince1970)"
        case .existing(let entry): "\(entry.persistentModelID.hashValue)"
        }
    }
}

struct TimesheetView: View {
    let timer: TimerService

    @AppStorage("timesheetMode") private var mode: TimesheetMode = .day
    @State private var weekStart = Week.start(of: .now)
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var editTarget: EntryEditTarget?

    private var isOnToday: Bool {
        weekStart == Week.start(of: .now) && selectedDay == Calendar.current.startOfDay(for: .now)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            WeekContent(
                timer: timer,
                weekStart: weekStart,
                mode: mode,
                selectedDay: $selectedDay,
                editTarget: $editTarget
            )
            TotalsBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editTarget) { target in
            EntryEditor(target: target, timer: timer)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Button { shiftWeek(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous week")
                Button { shiftWeek(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next week")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 1) {
                Text(Week.title(from: weekStart)).font(.title2.weight(.semibold))
                Text(isOnToday ? "This week" : weekDistance)
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !isOnToday {
                Button("Today") {
                    weekStart = Week.start(of: .now)
                    selectedDay = Calendar.current.startOfDay(for: .now)
                }
                .controlSize(.large)
            }
            Spacer()
            Picker("View", selection: $mode) {
                ForEach(TimesheetMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .fixedSize()
            Button { editTarget = .new(selectedDay) } label: {
                Label("New Entry", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("n")
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var weekDistance: String {
        let weeks = Week.calendar.dateComponents([.weekOfYear], from: Week.start(of: .now), to: weekStart).weekOfYear ?? 0
        switch weeks {
        case 0: return "This week"
        case -1: return "Last week"
        case 1: return "Next week"
        case ..<0: return "\(-weeks) weeks ago"
        default: return "In \(weeks) weeks"
        }
    }

    private func shiftWeek(_ weeks: Int) {
        let cal = Week.calendar
        weekStart = cal.date(byAdding: .weekOfYear, value: weeks, to: weekStart) ?? weekStart
        // Keep the same weekday selected.
        let offset = cal.dateComponents([.day], from: Week.start(of: selectedDay), to: selectedDay).day ?? 0
        selectedDay = cal.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
    }
}

/// Loads one week's entries via a date-range query.
private struct WeekContent: View {
    let timer: TimerService
    let weekStart: Date
    let mode: TimesheetMode
    @Binding var selectedDay: Date
    @Binding var editTarget: EntryEditTarget?

    @Query private var entries: [TimeEntry]

    init(timer: TimerService, weekStart: Date, mode: TimesheetMode, selectedDay: Binding<Date>, editTarget: Binding<EntryEditTarget?>) {
        self.timer = timer
        self.weekStart = weekStart
        self.mode = mode
        _selectedDay = selectedDay
        _editTarget = editTarget
        let end = Week.end(from: weekStart)
        _entries = Query(
            filter: #Predicate<TimeEntry> { $0.date >= weekStart && $0.date < end },
            sort: [SortDescriptor(\TimeEntry.date), SortDescriptor(\TimeEntry.createdAt)]
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            switch mode {
            case .day:
                VStack(spacing: 0) {
                    DayStrip(weekStart: weekStart, entries: entries, now: context.date, selectedDay: $selectedDay)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                    DayEntryList(
                        timer: timer,
                        day: selectedDay,
                        entries: entries.filter { $0.date == selectedDay },
                        now: context.date,
                        editTarget: $editTarget
                    )
                }
            case .week:
                WeekGrid(weekStart: weekStart, entries: entries, now: context.date,
                         onSelectDay: { selectedDay = $0 },
                         onEdit: { editTarget = $0 })
            }
        }
    }
}

private struct DayStrip: View {
    let weekStart: Date
    let entries: [TimeEntry]
    let now: Date
    @Binding var selectedDay: Date

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Week.days(from: weekStart), id: \.self) { day in
                dayButton(day)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Week").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(DurationFormat.short(BillingSummary.totalSeconds(entries, at: now)))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: 90, alignment: .leading)
            .card(padding: 12, cornerRadius: 12)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func dayButton(_ day: Date) -> some View {
        let total = BillingSummary.totalSeconds(entries.filter { $0.date == day }, at: now)
        let isSelected = day == selectedDay
        let isToday = Calendar.current.isDateInToday(day)
        let isRunning = entries.contains { $0.date == day && $0.isRunning }
        return Button {
            selectedDay = day
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption.weight(.semibold))
                    Text(day.formatted(.dateTime.day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if isRunning {
                        Circle().fill(.red).frame(width: 6, height: 6)
                    } else if isToday {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    }
                }
                Text(total > 0 ? DurationFormat.short(total) : "–")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(total > 0 ? .primary : .tertiary)
            }
            .card(padding: 12, cornerRadius: 12, tint: isSelected ? .accentColor : nil, highlighted: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DayEntryList: View {
    @Environment(\.modelContext) private var context
    let timer: TimerService
    let day: Date
    let entries: [TimeEntry]
    let now: Date
    @Binding var editTarget: EntryEditTarget?
    @State private var writeOffTarget: TimeEntry?
    @State private var writeOffReason = ""

    var body: some View {
        list
            .alert("Write off this time?", isPresented: Binding(get: { writeOffTarget != nil }, set: { if !$0 { writeOffTarget = nil } })) {
                TextField("Reason (optional)", text: $writeOffReason)
                Button("Write Off") {
                    if let entry = writeOffTarget { InvoiceBuilder.writeOff([entry], reason: writeOffReason) }
                    try? context.save()
                    writeOffReason = ""
                }
                Button("Cancel", role: .cancel) { writeOffReason = "" }
            } message: {
                Text("It stays in your timesheet but won't count as uninvoiced. You can undo this.")
            }
    }

    @ViewBuilder
    private var list: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label("No time on \(day.formatted(.dateTime.weekday(.wide)))", systemImage: "clock")
            } description: {
                Text("Start a timer from the menu bar, or add time manually.")
            } actions: {
                Button("New Entry") { editTarget = .new(day) }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.headline)
                        Spacer()
                        Text("\(entries.count) entr\(entries.count == 1 ? "y" : "ies") · \(DurationFormat.short(BillingSummary.totalSeconds(entries, at: now)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)

                    ForEach(entries) { entry in
                        EntryRow(
                            entry: entry, now: now, timer: timer,
                            onEdit: { editTarget = .existing(entry) },
                            onDuplicate: { duplicate(entry) },
                            onDelete: { delete(entry) },
                            onWriteOff: { writeOffTarget = entry }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
    }

    private func duplicate(_ entry: TimeEntry) {
        let copy = TimeEntry(task: entry.task, date: entry.date, durationSeconds: entry.liveDuration(at: now), note: entry.note)
        copy.isBillable = entry.isBillable
        context.insert(copy)
        try? context.save()
    }

    private func delete(_ entry: TimeEntry) {
        if entry.isRunning {
            timer.cancel()
        } else {
            context.delete(entry)
            try? context.save()
        }
    }
}

private struct EntryRow: View {
    let entry: TimeEntry
    let now: Date
    let timer: TimerService
    var onEdit: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    var onWriteOff: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(entry.task?.project?.client?.name ?? "No client")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if !entry.isBillable || !RateResolver.isBillable(entry.task) {
                        Tag(text: "Non-billable")
                    }
                    if entry.task?.project?.billingType == .fixedFee {
                        Tag(text: "Fixed fee", color: .purple)
                    }
                    if entry.isLocked {
                        Tag(text: lockLabel, color: entry.billingState == .writtenOff ? .orange : .green)
                            .help(entry.writeOffReason.map { "Written off: \($0)" } ?? "Invoiced time can't be edited")
                    }
                }
                Text(entry.task?.shortPath ?? "No task")
                    .font(.title3.weight(.medium))
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(DurationFormat.short(entry.liveDuration(at: now)))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if entry.isRunning, let started = entry.startedAt {
                    Text("since \(started.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if entry.isRunning {
                    Button { timer.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else if !entry.isLocked {
                    Button { timer.resume(entry) } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(.bordered)
                }
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .controlSize(.large)
        }
        .card(padding: 16, cornerRadius: 14, tint: entry.isRunning ? .red : nil, highlighted: entry.isRunning)
        .opacity(entry.billingState == .writtenOff ? 0.65 : 1)
        .scaleEffect(hovering ? 1.004 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .pointerStyle(.link)
        .help(entry.isLocked ? "View entry" : "Click to edit")
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Edit…", action: onEdit)
        Button("Duplicate", action: onDuplicate)
        Divider()
        if entry.billingState == .writtenOff {
            Button("Undo Write-off") { InvoiceBuilder.undoWriteOff([entry]) }
        } else {
            Button("Write Off…", action: onWriteOff).disabled(entry.isLocked || entry.isRunning)
        }
        Divider()
        Button("Delete", role: .destructive, action: onDelete).disabled(entry.isLocked)
    }

    private var lockLabel: String {
        switch entry.billingState {
        case .unbilled: ""
        case .billed: entry.invoice.map { "Invoice \($0.number)" } ?? "Invoiced"
        case .covered: entry.invoice.map { "Covered by \($0.number)" } ?? "Covered"
        case .writtenOff: "Written off"
        }
    }
}

/// Task × day totals for the week, grouped by client.
private struct WeekGrid: View {
    let weekStart: Date
    let entries: [TimeEntry]
    let now: Date
    var onSelectDay: (Date) -> Void
    var onEdit: (EntryEditTarget) -> Void

    private var days: [Date] { Week.days(from: weekStart) }

    private var rows: [(task: TaskType?, key: String)] {
        var seen = Set<String>()
        return entries
            .map { ($0.task, $0.task?.path ?? "No task") }
            .filter { seen.insert($0.1).inserted }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
            .map { (task: $0.0, key: $0.1) }
    }

    private enum Layout {
        static let taskMin: CGFloat = 240
        static let dayMin: CGFloat = 70
        static let total: CGFloat = 96
        static let spacing: CGFloat = 6
    }

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("No time this week", systemImage: "calendar",
                                   description: Text("Switch to Day view to add entries."))
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    header
                    ForEach(rows, id: \.key) { row in
                        taskRow(row)
                    }
                    totalsRow
                }
                .padding(20)
                .card(padding: 0, cornerRadius: 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: Rows

    private var header: some View {
        HStack(spacing: Layout.spacing) {
            Text("Task")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: Layout.taskMin, maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
            ForEach(days, id: \.self) { day in
                let isToday = Calendar.current.isDateInToday(day)
                Button { onSelectDay(day) } label: {
                    VStack(spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isToday ? Color.accentColor : .secondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.system(.title3, design: .rounded).weight(isToday ? .bold : .medium))
                            .foregroundStyle(isToday ? .white : .primary)
                            .frame(width: 34, height: 34)
                            .background(isToday ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .circle)
                    }
                    .frame(minWidth: Layout.dayMin, maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(day.formatted(.dateTime.weekday(.wide).day().month()))")
            }
            Text("Total")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Layout.total, alignment: .trailing)
                .padding(.trailing, 16)
        }
        .padding(.bottom, 8)
    }

    private func taskRow(_ row: (task: TaskType?, key: String)) -> some View {
        let rowEntries = entries.filter { ($0.task?.path ?? "No task") == row.key }
        let client = row.task?.project?.client
        return HStack(spacing: Layout.spacing) {
            HStack(spacing: 12) {
                Avatar(name: client?.name ?? "?", size: 32, imageData: client?.logoData)
                VStack(alignment: .leading, spacing: 2) {
                    Text(client?.name ?? "").font(.caption).foregroundStyle(.secondary)
                    Text(row.task?.shortPath ?? "No task").font(.body.weight(.medium)).lineLimit(1)
                }
            }
            .frame(minWidth: Layout.taskMin, maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            ForEach(days, id: \.self) { day in
                WeekCell(entries: rowEntries.filter { $0.date == day }, day: day, task: row.task,
                         now: now, minWidth: Layout.dayMin, onEdit: onEdit)
            }
            Text(DurationFormat.short(BillingSummary.totalSeconds(rowEntries, at: now)))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(width: Layout.total, alignment: .trailing)
                .padding(.trailing, 16)
        }
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
    }

    private var totalsRow: some View {
        HStack(spacing: Layout.spacing) {
            Text("Total")
                .font(.headline)
                .frame(minWidth: Layout.taskMin, maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
            ForEach(days, id: \.self) { day in
                let total = BillingSummary.totalSeconds(entries.filter { $0.date == day }, at: now)
                Text(total > 0 ? DurationFormat.short(total) : "–")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(total > 0 ? .primary : .tertiary)
                    .frame(minWidth: Layout.dayMin, maxWidth: .infinity)
            }
            Text(DurationFormat.short(BillingSummary.totalSeconds(entries, at: now)))
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .frame(width: Layout.total, alignment: .trailing)
                .padding(.trailing, 16)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Divider() }
        .padding(.top, 6)
    }
}

/// One task × day cell: click to edit the entry, pick from several, or add one.
private struct WeekCell: View {
    @Environment(\.modelContext) private var context
    let entries: [TimeEntry]
    let day: Date
    let task: TaskType?
    let now: Date
    let minWidth: CGFloat
    var onEdit: (EntryEditTarget) -> Void

    @State private var hovering = false
    @State private var choosing = false

    private var total: TimeInterval { BillingSummary.totalSeconds(entries, at: now) }
    private var running: Bool { entries.contains(where: \.isRunning) }

    var body: some View {
        Button(action: open) {
            Group {
                if total > 0 {
                    Text(DurationFormat.short(total))
                } else if hovering {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                } else {
                    Text("–")
                }
            }
            .font(.system(.body, design: .rounded).weight(total > 0 ? .medium : .regular))
            .monospacedDigit()
            .foregroundStyle(running ? AnyShapeStyle(.red) : total > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(minWidth: minWidth, maxWidth: .infinity, minHeight: 36)
            .background {
                if total > 0 || hovering {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(running ? AnyShapeStyle(Color.red.opacity(0.15))
                              : AnyShapeStyle(.background.opacity(hovering ? 0.9 : 0.6)))
                }
            }
            .overlay {
                if hovering { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.5)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entries.isEmpty ? "Add time for \(day.formatted(.dateTime.weekday(.wide)))"
              : entries.count == 1 ? "Edit entry" : "\(entries.count) entries")
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(day.formatted(.dateTime.weekday(.wide).day().month()))
                    .font(.headline)
                    .padding(.bottom, 4)
                ForEach(entries.sorted { $0.createdAt < $1.createdAt }) { entry in
                    Button {
                        choosing = false
                        onEdit(.existing(entry))
                    } label: {
                        HStack {
                            Text(entry.note.isEmpty ? "No note" : entry.note)
                                .foregroundStyle(entry.note.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer(minLength: 16)
                            Text(DurationFormat.short(entry.liveDuration(at: now))).monospacedDigit()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    .contextMenu {
                        Button("Edit…") { choosing = false; onEdit(.existing(entry)) }
                        Button("Delete", role: .destructive) { delete(entry) }
                            .disabled(entry.isLocked || entry.isRunning)
                    }
                    .safeAreaInset(edge: .trailing, spacing: 6) {
                        Button { delete(entry) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .disabled(entry.isLocked || entry.isRunning)
                            .help(entry.isLocked ? "Invoiced time can't be deleted"
                                  : entry.isRunning ? "Stop the timer first" : "Delete entry")
                    }
                }
                Divider().padding(.vertical, 4)
                Button {
                    choosing = false
                    onEdit(.new(day, task: task))
                } label: {
                    Label("Add entry", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(14)
            .frame(width: 280)
        }
    }

    private func delete(_ entry: TimeEntry) {
        guard !entry.isLocked, !entry.isRunning else { return }
        context.delete(entry)
        try? context.save()
        if entries.count <= 1 { choosing = false }
    }

    private func open() {
        switch entries.count {
        case 0: onEdit(.new(day, task: task))
        case 1: onEdit(.existing(entries[0]))
        default: choosing = true
        }
    }
}
