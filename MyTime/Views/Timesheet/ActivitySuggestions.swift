import SwiftData
import SwiftUI

/// Everything AI tools have reported that isn't on the timesheet yet, by day, to add or dismiss.
struct ReviewView: View {
    let timer: TimerService

    @Query(sort: \ActivityBeat.at) private var beats: [ActivityBeat]
    @Query(sort: \ActivityNote.at) private var notes: [ActivityNote]
    @Query private var projects: [Project]
    @Query(filter: #Predicate<TaskType> { !$0.isArchived }) private var allTasks: [TaskType]
    // Read so a change in Settings redraws the suggestions.
    @AppStorage(ActivitySettings.roundingKey) private var rounding = ActivitySettings.defaultRoundingMinutes
    @AppStorage(ActivitySettings.minimumKey) private var minimum = ActivitySettings.defaultMinimumMinutes
    @Query(sort: \TimeEntry.createdAt, order: .reverse) private var entries: [TimeEntry]

    /// Favourites then recent tasks, as one-click choices on each card.
    private var quickTasks: [TaskType] {
        let tasks = allTasks.filter(\.isSelectable).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let favourites = QuickStart.favourites(tasks: tasks, entries: entries)
        return favourites + QuickStart.recents(entries: entries, excluding: favourites)
    }

    @Query private var handled: [HandledMeeting]
    @AppStorage(MeetingSettings.enabledKey) private var meetingsEnabled = false
    private let calendars = CalendarStore.shared

    /// AI activity and meetings, latest day first and in time order within a day.
    private func items(now: Date) -> [ReviewItem] {
        let activity = ActivityTracker.suggestions(beats, notes: notes, projects: projects)
        let meetings = MeetingTracker.withOverlap(
            MeetingTracker.suggestions(calendars.events, handled: Set(handled.map(\.key)), projects: projects, now: now),
            activity: activity)
        return ReviewItem.merge(activity: activity, meetings: meetings)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let items = items(now: context.date)
            let days = ReviewItem.days(items)
            let quickTasks = quickTasks
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to review", systemImage: "sparkles")
                } description: {
                    Text("Time Claude Code spends working in your repos shows up here, with any labels you ask it to log "
                         + "(\"log this to MyTime\")"
                         + (meetingsEnabled ? ", and meetings from your calendars" : "")
                         + ". Add it to a task, or dismiss it.")
                } actions: {
                    if !meetingsEnabled {
                        SettingsLink { Text("Add Meetings from Calendars…") }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(days, id: \.self) { day in
                            let forDay = items.filter { $0.day == day }
                            HStack(alignment: .firstTextBaseline) {
                                Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                                    .font(.headline)
                                Spacer()
                                Text(DurationFormat.short(forDay.reduce(0) { $0 + $1.roundedDuration }))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 4)
                            .padding(.top, day == days.first ? 0 : 10)
                            ForEach(forDay) { item in
                                switch item {
                                case .activity(let suggestion):
                                    ActivitySuggestionRow(suggestion: suggestion, timer: timer, now: context.date, quickTasks: quickTasks)
                                case .meeting(let suggestion):
                                    MeetingSuggestionRow(suggestion: suggestion, timer: timer, now: context.date,
                                                         quickTasks: quickTasks, calendars: calendars.calendars)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Pick up anything logged or committed since the last poll, so it's here when you look.
            if let poller = ActivityPoller.current {
                poller.poll(includingCommits: true)
            } else {
                ActivityTracker.ingest(context: modelContext, running: timer.activeEntries)
            }
            calendars.refresh()
        }
    }

    @Environment(\.modelContext) private var modelContext
}

/// "1:20 of AI activity to review" on a timesheet day, linking to the Review tab.
struct ActivityReviewBanner: View {
    let suggestions: [ActivityTracker.Suggestion]
    var meetings: [MeetingTracker.Suggestion] = []
    @AppStorage("mainSection") private var section: MainSection = .timesheet

    private var what: String {
        switch (suggestions.isEmpty, meetings.isEmpty) {
        case (false, false): "AI activity and meetings"
        case (true, false): "meetings"
        default: "AI activity"
        }
    }

    var body: some View {
        if !suggestions.isEmpty || !meetings.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: suggestions.isEmpty ? "calendar" : "sparkles").foregroundStyle(.purple)
                Text("\(DurationFormat.short(suggestions.reduce(0) { $0 + $1.roundedDuration } + meetings.reduce(0) { $0 + $1.roundedDuration })) of \(what) to review")
                    .monospacedDigit()
                Spacer()
                Button("Review") { section = .review }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
            }
            .card(padding: 12, cornerRadius: 12, tint: .purple, highlighted: true)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }
}

/// Favourite and recent tasks as one-click choices on a suggestion card.
struct QuickTaskChips: View {
    let tasks: [TaskType]
    @Binding var selection: TaskType?
    var tint: Color

    var body: some View {
        if !tasks.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tasks) { quick in
                        let selected = quick.persistentModelID == selection?.persistentModelID
                        Button { selection = quick } label: {
                            HStack(spacing: 6) {
                                Avatar(name: quick.project?.client?.name ?? "?", size: 16, imageData: quick.project?.client?.logoData)
                                Text(quick.shortPath).lineLimit(1)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(selected ? tint : nil)
                        .controlSize(.small)
                        .help(quick.path)
                    }
                }
            }
        }
    }
}

private struct ActivitySuggestionRow: View {
    @Environment(\.modelContext) private var context
    let suggestion: ActivityTracker.Suggestion
    let timer: TimerService
    let now: Date
    let quickTasks: [TaskType]

    @State private var task: TaskType?
    @State private var remember = true
    @State private var durationText: String
    @State private var note: String
    /// Set once you edit the duration, so a growing in-progress suggestion doesn't overwrite your number.
    @State private var editedDuration = false
    /// The note Apple Intelligence wrote from what was worked on, while you haven't changed it.
    @State private var writtenNote: String?
    @State private var writingNote = false

    init(suggestion: ActivityTracker.Suggestion, timer: TimerService, now: Date, quickTasks: [TaskType]) {
        self.suggestion = suggestion
        self.timer = timer
        self.now = now
        self.quickTasks = quickTasks
        _task = State(initialValue: (suggestion.project ?? suggestion.guess)?.suggestedTask)
        _durationText = State(initialValue: DurationFormat.short(suggestion.roundedDuration))
        _note = State(initialValue: suggestion.note)
    }

    /// Worth offering "remember" only when accepting would change what's saved on the project.
    private var canRemember: Bool {
        guard let task else { return false }
        guard let project = suggestion.project else { return true }
        return task.project?.persistentModelID == project.persistentModelID && project.activityTaskID != task.uuid
    }

    private var duration: TimeInterval? {
        editedDuration ? DurationFormat.parse(durationText) : suggestion.roundedDuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(suggestion.sources.map(ActivityTracker.sourceName).joined(separator: " + "))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if suggestion.isOngoing(at: now) {
                            Tag(text: "In progress", color: .purple)
                                .help("Still active. Adding it now adds the time so far; anything after starts a new suggestion.")
                        }
                        if suggestion.isEstimate {
                            Tag(text: "Estimate", color: .orange)
                                .help("No activity was measured, so this is the time the tool estimated.")
                        }
                    }
                    Text(title)
                        .font(.title3.weight(.medium))
                        .help(ActivityTracker.abbreviate(suggestion.folder))
                    TextField(writingNote ? "Writing a note…" : "Note, 1–3 words (appears on invoices)", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 520)
                        .padding(.vertical, 3)
                        .help(note == writtenNote && !note.isEmpty
                              ? "Written on this Mac by Apple Intelligence from what you worked on. Change it if you like."
                              : "Appears on invoices")
                        .onChange(of: suggestion.note) { old, new in
                            // A label logged while this is on screen replaces the note, unless you've changed it.
                            if note == old || note == writtenNote { note = new }
                        }
                        // Also tried again when Apple Intelligence becomes ready (the view redraws every 15 seconds).
                        .task(id: suggestion.worked + [NoteWriter.unavailableReason ?? ""]) { await writeNote() }
                    if !times.isEmpty {
                        Text(times)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if !suggestion.worked.isEmpty {
                        Text("Worked on: " + suggestion.worked.joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(suggestion.worked.joined(separator: "\n"))
                    }
                }
                Spacer(minLength: 12)
                TextField("0:00", text: Binding(
                    get: { editedDuration ? durationText : DurationFormat.short(suggestion.roundedDuration) },
                    set: { durationText = $0; editedDuration = true }
                ))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .frame(width: 80)
                .help("Time to add, e.g. 1:30 or 45m")
            }

            QuickTaskChips(tasks: quickTasks, selection: $task, tint: .purple)

            HStack(spacing: 10) {
                TaskPicker(selection: $task, placeholder: "Add to project…")
                    .labelsHidden()
                    .frame(maxWidth: 420)
                if canRemember {
                    Toggle(suggestion.project == nil ? "Always for this folder" : "Use this task next time", isOn: $remember)
                        .toggleStyle(.checkbox)
                        .help(suggestion.project == nil
                              ? "Link \(ActivityTracker.abbreviate(suggestion.folder)) to this project, so its activity is suggested there"
                              : "Suggest this project's activity on this task from now on")
                }
                Spacer(minLength: 8)
                Menu("Dismiss") {
                    Button("Ignore \((suggestion.folder as NSString).lastPathComponent) from Now On") {
                        ActivityTracker.ignore(suggestion.folder, context: context)
                    }
                } primaryAction: {
                    ActivityTracker.dismiss(suggestion, context: context)
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Don't add this time. Use the arrow to stop tracking this folder (Settings › AI Activity to undo).")
                Button("Add to Timesheet", action: accept)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(task == nil || duration == nil)
                    .help("Adds to this day's entry for the task, or starts one")
            }
            .controlSize(.large)
        }
        .card(padding: 16, cornerRadius: 14, tint: .purple, highlighted: true)
    }

    private var title: String {
        if let project = suggestion.project {
            return TaskPicker.title(project)
        }
        let folder = (suggestion.folder as NSString).lastPathComponent
        if let guess = suggestion.guess {
            return "\(folder) · not linked, looks like \(TaskPicker.title(guess))"
        }
        return "\(folder) · not linked to a project"
    }

    private var times: String {
        suggestion.blocks.map { block in
            let start = block.start.formatted(date: .omitted, time: .shortened)
            let end = block.end.formatted(date: .omitted, time: .shortened)
            let range = start == end ? start : "\(start)–\(end)"
            return block.fromCommits ? "\(range) (commits)" : range
        }
        .joined(separator: " · ")
    }

    /// Fills an empty note from the day's session titles and commits. Labels you logged come first, and a note
    /// you've typed is never replaced.
    private func writeNote() async {
        guard suggestion.note.isEmpty, !suggestion.worked.isEmpty, NoteWriter.unavailableReason == nil else { return }
        writingNote = note.isEmpty
        let written = await NoteWriter.shared.note(for: suggestion.worked)
        writingNote = false
        guard let written, suggestion.note.isEmpty else { return }
        if note.isEmpty || note == writtenNote { note = written }
        writtenNote = written
    }

    private func accept() {
        guard let task, let duration else { return }
        ActivityTracker.accept(suggestion, task: task, duration: duration, note: note,
                               remember: remember && canRemember, context: context)
        timer.refresh()
    }
}
