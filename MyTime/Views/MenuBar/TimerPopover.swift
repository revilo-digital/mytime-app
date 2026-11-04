import SwiftData
import SwiftUI

struct TimerPopover: View {
    let timer: TimerService

    @Query(filter: #Predicate<TaskType> { !$0.isArchived })
    private var allTasks: [TaskType]

    @Query(sort: \TimeEntry.createdAt, order: .reverse)
    private var entries: [TimeEntry]

    @AppStorage(TimerService.lastTaskKey) private var lastTaskID = ""
    @State private var selectedTask: TaskType?
    @State private var note = ""
    @State private var editingID: PersistentIdentifier?
    @State private var addingEntry = false
    /// Showing the task picker to start another timer while one is running.
    @State private var startingAlongside = false

    /// Active tasks on active projects and clients, sorted by path ("Client / End client / Project / Task").
    private var tasks: [TaskType] {
        allTasks
            .filter(\.isSelectable)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var favouriteTasks: [TaskType] { QuickStart.favourites(tasks: tasks, entries: entries) }

    /// The last three tasks tracked that aren't already favourites.
    private var recentTasks: [TaskType] { QuickStart.recents(entries: entries, excluding: favouriteTasks) }

    private var todaysEntries: [TimeEntry] {
        let today = Calendar.current.startOfDay(for: .now)
        return entries.filter { $0.date == today }
    }

    /// Today's paused timers, oldest first (matches `TimerService.pausedEntries`).
    private var pausedEntries: [TimeEntry] {
        todaysEntries.filter { $0.isPaused && !$0.isLocked }.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if timer.isRunning {
                ForEach(timer.activeEntries) { entry in
                    RunningTimerView(timer: timer, entry: entry, compact: timer.activeEntries.count > 1,
                                     isPrimary: !startingAlongside && entry === timer.activeEntries.last)
                }
                if startingAlongside {
                    startView
                } else {
                    Button { startingAlongside = true } label: {
                        Label("Run another timer alongside", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .help("Start a second timer without stopping this one — both record their full time")
                }
            } else {
                startView
            }

            if !pausedEntries.isEmpty {
                pausedSection
            }

            if !favouriteTasks.isEmpty {
                quickStartSection("Favourites", systemImage: "star.fill", tasks: favouriteTasks)
            }
            if !recentTasks.isEmpty {
                quickStartSection("Recent", systemImage: "clock.arrow.circlepath", tasks: recentTasks)
            }

            Divider()
            todayList
            Divider()
            HStack(spacing: 16) {
                Button { AppWindows.requestMainWindow() } label: {
                    Label("Open MyTime", systemImage: "macwindow")
                }
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("Quit", systemImage: "power")
                }
                .help("Quit MyTime")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
        }
        .padding(20)
        .frame(width: 380)
        .onAppear(perform: restoreSelection)
        .onChange(of: timer.activeEntries.map(\.persistentModelID)) {
            startingAlongside = false
            restoreSelection()
        }
        .onChange(of: selectedTask?.persistentModelID) {
            // Remember picks straight away, even before Start is pressed.
            if let selectedTask { timer.remember(selectedTask) }
        }
    }

    // MARK: Start

    private var startView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(startingAlongside ? "Start another timer" : "Start timer").font(.title3.weight(.semibold))
                Spacer()
                if startingAlongside {
                    Button { startingAlongside = false } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Cancel")
                }
            }
            TaskPicker(selection: $selectedTask)
                .labelsHidden()
                .controlSize(.large)
            NoteField(text: $note, placeholder: "What are you working on?", onSubmit: startSelected)
            Button(action: startSelected) {
                Label(startingAlongside ? "Start alongside" : "Start", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.extraLarge)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedTask == nil || selectedTask.map(isRunning) == true)
            if tasks.isEmpty {
                Text("Add a client, project and task in MyTime first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var pausedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Paused", systemImage: "pause.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(pausedEntries) { entry in
                PausedTimerRow(entry: entry, timer: timer)
            }
        }
    }

    private func quickStartSection(_ title: String, systemImage: String, tasks: [TaskType]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(tasks) { task in
                let isActive = isRunning(task)
                let hasEntryToday = todaysEntries.contains { !$0.isLocked && $0.task?.persistentModelID == task.persistentModelID }
                HStack {
                    Button {
                        start(task, note: "")
                    } label: {
                        HStack {
                            Image(systemName: isActive ? "record.circle" : "play.fill")
                                .foregroundStyle(isActive ? .red : .accentColor)
                                .frame(width: 16)
                            ClientTile(client: task.project?.client, size: 18)
                            Text(task.path).lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isActive)
                    .help(hasEntryToday ? "Continue today's timer" : timer.isRunning ? "Switch to this task" : "Start timer")
                    if timer.isRunning, !isActive {
                        AlongsideButton { start(task, note: "", alongside: true) }
                    }
                    FavouriteStar(task: task)
                }
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: Today

    private var todayList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today").font(.subheadline.weight(.semibold))
                Button { addingEntry.toggle(); editingID = nil } label: {
                    Label("Add time", systemImage: addingEntry ? "xmark.circle" : "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Add time you forgot to track")
                Spacer()
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(DurationFormat.short(todaysEntries.reduce(0) { $0 + $1.liveDuration(at: context.date) }))
                        .monospacedDigit()
                        .font(.system(.title3, design: .rounded).weight(.bold))
                }
            }
            if addingEntry {
                PopoverNewEntry(initialTask: selectedTask) { addingEntry = false }
            }
            if todaysEntries.isEmpty {
                Text("Nothing tracked yet").foregroundStyle(.secondary).font(.callout)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(todaysEntries) { entry in
                        PopoverEntryRow(entry: entry, timer: timer, isEditing: Binding(
                            get: { editingID == entry.persistentModelID },
                            set: { editingID = $0 ? entry.persistentModelID : nil }
                        ))
                    }
                }
            }
            .frame(maxHeight: editingID == nil ? 240 : 400)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func startSelected() {
        guard let task = selectedTask else { return }
        start(task, note: note, alongside: startingAlongside)
        note = ""
    }

    private func start(_ task: TaskType, note: String, alongside: Bool = false) {
        timer.start(task: task, note: note, alongside: alongside)
        lastTaskID = task.uuid.uuidString
        selectedTask = task
    }

    private func isRunning(_ task: TaskType) -> Bool {
        timer.activeEntries.contains { $0.task?.persistentModelID == task.persistentModelID }
    }

    /// Shows the remembered project and task — the last one picked or tracked.
    private func restoreSelection() {
        guard !timer.isRunning else { return }
        if let remembered = timer.lastUsedTask(),
           remembered.persistentModelID != selectedTask?.persistentModelID {
            selectedTask = remembered
        } else if selectedTask == nil {
            selectedTask = tasks.first
        }
    }
}

private struct RunningTimerView: View {
    let timer: TimerService
    @Bindable var entry: TimeEntry
    /// A one-row card when several timers are stacked.
    var compact = false
    /// The newest timer gets the Return-key Stop, so there's only one default button.
    var isPrimary = true

    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            Group {
                if compact {
                    HStack(spacing: 10) {
                        taskLabel(tileSize: 28)
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 0) {
                            clock(size: 26)
                            since
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(.red).frame(width: 7, height: 7)
                            Text("Running").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            since
                        }
                        clock(size: 44)
                        taskLabel(tileSize: 36)
                    }
                }
            }
            .padding(compact ? 12 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)))

            NoteField(text: $entry.note, placeholder: "Add a note", lines: compact ? 1...4 : 3...6)

            // Confirm inline: a confirmationDialog from the menu bar window never runs its action.
            if confirmDiscard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Discard the running timer?").font(.callout.weight(.semibold))
                    Text("The time tracked on this entry will be deleted.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Keep") { confirmDiscard = false }
                            .keyboardShortcut(.cancelAction)
                        Button("Discard", role: .destructive) { timer.cancel(entry) }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    }
                }
            } else {
                actions
            }
        }
        .onChange(of: entry.persistentModelID) { confirmDiscard = false }
    }

    private func clock(size: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(DurationFormat.clock(entry.liveDuration(at: context.date)))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    private var since: some View {
        if let started = entry.startedAt {
            Text("since \(started.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func taskLabel(tileSize: CGFloat) -> some View {
        HStack(spacing: 10) {
            ClientTile(client: entry.task?.project?.client, size: tileSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.task?.project?.client?.name ?? "").font(.caption).foregroundStyle(.secondary)
                Text(entry.task?.shortPath ?? "No task").font(.headline).lineLimit(1)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                timer.pause(entry)
            } label: {
                Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
            }
            .controlSize(compact ? .large : .extraLarge)
            .help("Pause — pick it up again from the Paused list")
            Button {
                timer.stop(entry)
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .controlSize(compact ? .large : .extraLarge)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(isPrimary ? .defaultAction : nil)
            Button(role: .destructive) { confirmDiscard = true } label: {
                Image(systemName: "trash")
            }
            .controlSize(compact ? .large : .extraLarge)
            .help("Discard this timer")
        }
    }
}

/// Stars or unstars a task. A task that's only a favourite through its starred project
/// shows filled too, and unstarring it unstars the project.
private struct FavouriteStar: View {
    @Environment(\.modelContext) private var context
    let task: TaskType

    private var viaProject: Bool { !task.isFavourite && task.project?.isFavourite == true }
    private var isOn: Bool { task.isFavourite || viaProject }

    var body: some View {
        Button {
            if viaProject { task.project?.isFavourite = false } else { task.isFavourite.toggle() }
            try? context.save()
        } label: {
            Image(systemName: isOn ? "star.fill" : "star")
                .foregroundStyle(isOn ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.borderless)
        .help(viaProject ? "Remove \(task.project?.name ?? "the project") from favourites"
              : isOn ? "Remove from favourites" : "Add to favourites")
    }
}

/// Starts a timer without pausing the running ones.
private struct AlongsideButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Run alongside — keeps the current timer going, both record their full time")
    }
}

/// A paused timer: resume it (pausing whatever is running) or run it alongside, or stop it for good.
private struct PausedTimerRow: View {
    let entry: TimeEntry
    let timer: TimerService

    var body: some View {
        HStack(spacing: 10) {
            Button { timer.resume(entry) } label: {
                Image(systemName: "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .help(timer.isRunning ? "Switch to this timer (pauses the running one)" : "Resume")
            if timer.isRunning {
                AlongsideButton { timer.resume(entry, alongside: true) }
            }
            ClientTile(client: entry.task?.project?.client, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.task?.path ?? "No task").lineLimit(1)
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(DurationFormat.short(entry.durationSeconds))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button { timer.stopPaused(entry) } label: {
                Image(systemName: "stop.circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Stop — keeps the time and removes it from Paused")
        }
        .font(.callout)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }
}

/// The client's avatar tile, sized for popover rows; nothing for an entry with no task.
private struct ClientTile: View {
    let client: Client?
    let size: CGFloat

    var body: some View {
        if let client {
            Avatar(name: client.name, size: size, imageData: client.logoData)
        }
    }
}

/// Roomy multi-line note field used in the popover.
private struct NoteField: View {
    @Binding var text: String
    var placeholder: String
    var lines: ClosedRange<Int> = 3...6
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(lines)
            .font(.body)
            .padding(10)
            .background(.background.opacity(0.5), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .onSubmit(onSubmit)
    }
}

/// A Today entry: click to expand and edit time, note and task in place
/// (sheets don't work reliably from a menu bar window).
private struct PopoverEntryRow: View {
    @Environment(\.modelContext) private var context
    let entry: TimeEntry
    let timer: TimerService
    @Binding var isEditing: Bool

    @State private var durationText = ""
    @State private var note = ""
    @State private var task: TaskType?
    @State private var confirmDelete = false
    @State private var hovering = false
    @FocusState private var durationFocused: Bool

    private var parsed: TimeInterval? { DurationFormat.parse(durationText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            if isEditing { editor }
        }
        .padding(isEditing ? 12 : 6)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isEditing ? AnyShapeStyle(.quaternary.opacity(0.6))
                      : hovering ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear))
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isEditing)
        .onChange(of: isEditing) { confirmDelete = false }
    }

    private var summary: some View {
        HStack {
            ClientTile(client: entry.task?.project?.client, size: 20)
            VStack(alignment: .leading) {
                Text(entry.task?.path ?? "No task").lineLimit(1)
                if !entry.note.isEmpty, !isEditing {
                    Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if entry.isRunning {
                Image(systemName: "record.circle").foregroundStyle(.red)
            } else if entry.isLocked {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Invoiced or written off — can't be edited")
            } else if !isEditing {
                Button { timer.resume(entry) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
                    .help(timer.isRunning ? "Continue this entry (pauses the running timer)" : "Continue this entry")
                if timer.isRunning {
                    AlongsideButton { timer.resume(entry, alongside: true) }
                }
            }
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(DurationFormat.short(entry.liveDuration(at: context.date)))
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(entry.isRunning ? .red : .primary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onTapGesture { if !entry.isLocked { toggle() } }
        .help(entry.isLocked ? "" : isEditing ? "Click to close" : "Click to edit")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TaskPicker(selection: $task)
                .labelsHidden()
            HStack(spacing: 8) {
                TextField("0:00", text: $durationText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                    .frame(width: 90)
                    .focused($durationFocused)
                    .onSubmit(save)
                ForEach([-15, 15], id: \.self) { minutes in
                    Button(minutes > 0 ? "+15m" : "−15m") { nudge(minutes) }
                        .controlSize(.small)
                }
                Spacer()
                if parsed == nil {
                    Text("e.g. 1:30").font(.caption).foregroundStyle(.red)
                } else if entry.isRunning {
                    Text("keeps running").font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("Note", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .padding(8)
                .background(.background.opacity(0.5), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            // Confirm inline: a confirmationDialog from the menu bar window never runs its action.
            if confirmDelete {
                HStack {
                    Text("Delete this entry?").font(.callout)
                    Spacer()
                    Button("Keep") { confirmDelete = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Delete", role: .destructive, action: delete)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            } else {
                actions
            }
        }
    }

    private var actions: some View {
        HStack {
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .help("Delete entry")
            Spacer()
            Button("Cancel") { isEditing = false }
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(parsed == nil || task == nil)
        }
    }

    private func delete() {
        if entry.isRunning { timer.cancel(entry) } else { context.delete(entry); try? context.save() }
        isEditing = false
    }

    private func toggle() {
        if isEditing { isEditing = false; return }
        durationText = DurationFormat.short(entry.liveDuration())
        note = entry.note
        task = entry.task
        isEditing = true
        durationFocused = true
    }

    private func nudge(_ minutes: Int) {
        let current = parsed ?? entry.liveDuration()
        durationText = DurationFormat.short(max(0, current + Double(minutes * 60)))
    }

    private func save() {
        guard let seconds = parsed, let task else { return }
        entry.task = task
        entry.note = note
        // Only touch the time if it changed, so seconds aren't lost to h:mm rounding.
        if durationText != DurationFormat.short(entry.liveDuration()) {
            if entry.isRunning {
                // Re-base the running timer so it carries on from the new total.
                entry.durationSeconds = seconds
                entry.startedAt = .now
                timer.refresh()
            } else {
                entry.durationSeconds = seconds
            }
        }
        try? context.save()
        isEditing = false
    }
}

/// Inline form for adding a finished entry to today from the popover.
private struct PopoverNewEntry: View {
    @Environment(\.modelContext) private var context
    var initialTask: TaskType?
    var onDone: () -> Void

    @State private var task: TaskType?
    @State private var durationText = ""
    @State private var note = ""
    @FocusState private var durationFocused: Bool

    private var parsed: TimeInterval? { DurationFormat.parse(durationText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TaskPicker(selection: $task).labelsHidden()
            HStack(spacing: 8) {
                TextField("0:00", text: $durationText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                    .frame(width: 90)
                    .focused($durationFocused)
                    .onSubmit(save)
                ForEach([15, 30, 60], id: \.self) { minutes in
                    Button(minutes == 60 ? "1h" : "\(minutes)m") {
                        durationText = DurationFormat.short(Double(minutes * 60))
                    }
                    .controlSize(.small)
                }
                Spacer()
                if !durationText.isEmpty, parsed == nil {
                    Text("e.g. 1:30").font(.caption).foregroundStyle(.red)
                }
            }
            TextField("Note", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .padding(8)
                .background(.background.opacity(0.5), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Add", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(task == nil || (parsed ?? 0) <= 0)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
        .onAppear {
            task = initialTask
            durationFocused = true
        }
    }

    private func save() {
        guard let task, let seconds = parsed, seconds > 0 else { return }
        let entry = TimeEntry(task: task, date: .now, durationSeconds: seconds, note: note)
        entry.isBillable = RateResolver.isBillable(task)
        context.insert(entry)
        try? context.save()
        onDone()
    }
}
