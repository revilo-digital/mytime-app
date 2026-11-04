import SwiftData
import SwiftUI

/// Everything AI tools have reported that isn't on the timesheet yet, by day, to add or dismiss.
struct ReviewView: View {
    let timer: TimerService

    @Query(sort: \ActivityBeat.at) private var beats: [ActivityBeat]
    @Query(sort: \ActivityNote.at) private var notes: [ActivityNote]
    @Query private var projects: [Project]

    private var suggestions: [ActivityTracker.Suggestion] {
        ActivityTracker.suggestions(beats, notes: notes, projects: projects).reversed()
    }

    private var days: [Date] {
        var seen = Set<Date>()
        return suggestions.map(\.day).filter { seen.insert($0).inserted }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let suggestions = suggestions
            if suggestions.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to review", systemImage: "sparkles")
                } description: {
                    Text("Time Claude Code spends working in your repos shows up here, with any labels you ask it to log "
                         + "(\"log this to MyTime\"). Add it to a task, or dismiss it.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(days, id: \.self) { day in
                            let forDay = suggestions.filter { $0.day == day }
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
                            ForEach(forDay) { suggestion in
                                ActivitySuggestionRow(suggestion: suggestion, timer: timer, now: context.date)
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
            // Pick up anything logged since the last poll, so a label Claude just logged is here.
            ActivityTracker.ingest(context: modelContext, running: timer.activeEntries)
        }
    }

    @Environment(\.modelContext) private var modelContext
}

/// "1:20 of AI activity to review" on a timesheet day, linking to the Review tab.
struct ActivityReviewBanner: View {
    let suggestions: [ActivityTracker.Suggestion]
    @AppStorage("mainSection") private var section: MainSection = .timesheet

    var body: some View {
        if !suggestions.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("\(DurationFormat.short(suggestions.reduce(0) { $0 + $1.roundedDuration })) of AI activity to review")
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

private struct ActivitySuggestionRow: View {
    @Environment(\.modelContext) private var context
    let suggestion: ActivityTracker.Suggestion
    let timer: TimerService
    let now: Date

    @State private var task: TaskType?
    @State private var remember = true
    @State private var durationText: String
    @State private var note: String
    /// Set once you edit the duration, so a growing in-progress suggestion doesn't overwrite your number.
    @State private var editedDuration = false

    init(suggestion: ActivityTracker.Suggestion, timer: TimerService, now: Date) {
        self.suggestion = suggestion
        self.timer = timer
        self.now = now
        _task = State(initialValue: suggestion.project?.activityTask)
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
                    if !times.isEmpty {
                        Text(times)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
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

            TextField("Note, 1–3 words (appears on invoices)", text: $note)
                .textFieldStyle(.roundedBorder)
                .onChange(of: suggestion.note) { old, new in
                    // A label logged while this is on screen joins the note, unless you've changed it.
                    if note == old { note = new }
                }

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
                Button("Dismiss") { ActivityTracker.dismiss(suggestion, context: context) }
                    .help("Don't add this time")
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
        return "\((suggestion.folder as NSString).lastPathComponent) · not linked to a project"
    }

    private var times: String {
        suggestion.blocks.map { block in
            let start = block.start.formatted(date: .omitted, time: .shortened)
            let end = block.end.formatted(date: .omitted, time: .shortened)
            return start == end ? start : "\(start)–\(end)"
        }
        .joined(separator: " · ")
    }

    private func accept() {
        guard let task, let duration else { return }
        ActivityTracker.accept(suggestion, task: task, duration: duration, note: note,
                               remember: remember && canRemember, context: context)
        timer.refresh()
    }
}
