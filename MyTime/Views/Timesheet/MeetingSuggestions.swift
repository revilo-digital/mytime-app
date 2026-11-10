import SwiftData
import SwiftUI

/// One card in Review: a day's AI activity for a project, or one meeting.
enum ReviewItem: Identifiable {
    case activity(ActivityTracker.Suggestion)
    case meeting(MeetingTracker.Suggestion)

    var id: String {
        switch self {
        case .activity(let suggestion): suggestion.id
        case .meeting(let suggestion): suggestion.id
        }
    }

    var day: Date {
        switch self {
        case .activity(let suggestion): suggestion.day
        case .meeting(let suggestion): suggestion.day
        }
    }

    var start: Date {
        switch self {
        case .activity(let suggestion): suggestion.start
        case .meeting(let suggestion): suggestion.start
        }
    }

    var roundedDuration: TimeInterval {
        switch self {
        case .activity(let suggestion): suggestion.roundedDuration
        case .meeting(let suggestion): suggestion.roundedDuration
        }
    }

    /// Latest day first; within a day, in the order things happened.
    static func merge(activity: [ActivityTracker.Suggestion], meetings: [MeetingTracker.Suggestion]) -> [ReviewItem] {
        (activity.map(ReviewItem.activity) + meetings.map(ReviewItem.meeting))
            .sorted { $0.day != $1.day ? $0.day > $1.day : $0.start < $1.start }
    }

    static func days(_ items: [ReviewItem]) -> [Date] {
        var seen = Set<Date>()
        return items.map(\.day).filter { seen.insert($0).inserted }
    }
}

/// A meeting from your calendar, to add to a task or dismiss.
struct MeetingSuggestionRow: View {
    @Environment(\.modelContext) private var context
    let suggestion: MeetingTracker.Suggestion
    let timer: TimerService
    let now: Date
    let quickTasks: [TaskType]
    let calendars: [CalendarStore.CalendarInfo]

    @State private var task: TaskType?
    @State private var remember = true
    @State private var durationText: String
    @State private var note: String
    @State private var editedDuration = false

    init(suggestion: MeetingTracker.Suggestion, timer: TimerService, now: Date, quickTasks: [TaskType],
         calendars: [CalendarStore.CalendarInfo]) {
        self.suggestion = suggestion
        self.timer = timer
        self.now = now
        self.quickTasks = quickTasks
        self.calendars = calendars
        _task = State(initialValue: (suggestion.project ?? suggestion.guess)?.suggestedMeetingTask)
        _durationText = State(initialValue: DurationFormat.short(suggestion.roundedDuration))
        _note = State(initialValue: suggestion.note)
    }

    private var calendarColor: Color {
        calendars.first { $0.id == suggestion.event.calendarID }?.color.map(Color.init(nsColor:)) ?? .blue
    }

    /// What "Always for…" would save, or nil when ticking it would change nothing.
    private var rememberLabel: String? {
        guard let task, let project = task.project else { return nil }
        if suggestion.project?.persistentModelID == project.persistentModelID {
            return project.meetingTaskID == task.uuid ? nil : "Use this task for meetings next time"
        }
        let links = suggestion.rememberLinks
        guard !links.isEmpty else { return nil }
        let names = links.map { MeetingTracker.describe($0) }
        let shown = names.count > 2 ? names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
            : names.joined(separator: " and ")
        return "Always for \(shown)"
    }

    private var duration: TimeInterval? {
        editedDuration ? DurationFormat.parse(durationText) : suggestion.roundedDuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "calendar")
                    .foregroundStyle(calendarColor)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(source)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if suggestion.isOngoing(at: now) {
                            Tag(text: "In progress", color: .blue)
                                .help("Ends at \(suggestion.event.end.formatted(date: .omitted, time: .shortened)). "
                                      + "Adding it now adds the scheduled length.")
                        }
                        if suggestion.overlap >= 60 {
                            Tag(text: "\(DurationFormat.short(suggestion.overlap)) overlaps AI activity", color: .orange)
                                .help("Some of this meeting is also in an AI activity suggestion for the day. "
                                      + "Shorten one of them so that time isn't counted twice.")
                        }
                    }
                    Text(title)
                        .font(.title3.weight(.medium))
                    TextField("Note, 1–3 words (appears on invoices)", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 520)
                        .padding(.vertical, 3)
                    Text(details)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .help(suggestion.event.attendees.joined(separator: "\n"))
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

            QuickTaskChips(tasks: quickTasks, selection: $task, tint: .blue)

            HStack(spacing: 10) {
                TaskPicker(selection: $task, placeholder: "Add to project…")
                    .labelsHidden()
                    .frame(maxWidth: 420)
                if let rememberLabel {
                    Toggle(rememberLabel, isOn: $remember)
                        .toggleStyle(.checkbox)
                        .lineLimit(1)
                        .help("Suggest meetings like this on this project and task from now on. "
                              + "Remove it under Projects › edit › Meetings.")
                }
                Spacer(minLength: 8)
                if suggestion.event.seriesID != nil {
                    Menu("Dismiss") {
                        Button("Ignore This Series from Now On") {
                            MeetingTracker.ignoreSeries(suggestion, context: context)
                        }
                    } primaryAction: {
                        MeetingTracker.dismiss(suggestion, context: context)
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .help("Don't add this meeting. Use the arrow to stop suggesting this recurring meeting "
                          + "(Settings › Calendars to undo).")
                } else {
                    Button("Dismiss") { MeetingTracker.dismiss(suggestion, context: context) }
                        .help("Don't add this meeting")
                }
                Button("Add to Timesheet", action: accept)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(task == nil || duration == nil)
                    .help("Adds to this day's entry for the task, or starts one")
            }
            .controlSize(.large)
        }
        .card(padding: 16, cornerRadius: 14, tint: .blue, highlighted: true)
    }

    private var source: String {
        let event = suggestion.event
        let account = event.accountTitle.isEmpty || event.accountTitle == event.calendarTitle ? "" : " · \(event.accountTitle)"
        return "Calendar · \(event.calendarTitle)\(account)"
    }

    private var title: String {
        let meeting = suggestion.event.title.isEmpty ? "Meeting" : suggestion.event.title
        if let project = suggestion.project {
            return "\(meeting) · \(TaskPicker.title(project))"
        }
        if let guess = suggestion.guess {
            return "\(meeting) · not linked, looks like \(TaskPicker.title(guess))"
        }
        return "\(meeting) · not linked to a project"
    }

    private var details: String {
        let event = suggestion.event
        let range = "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))"
        let people = suggestion.peopleLinks.map { MeetingTracker.split($0).value }
        guard !people.isEmpty else { return range }
        let shown = people.count > 3 ? people.prefix(3).joined(separator: ", ") + " +\(people.count - 3)" : people.joined(separator: ", ")
        return "\(range) · with \(shown)"
    }

    private func accept() {
        guard let task, let duration else { return }
        MeetingTracker.accept(suggestion, task: task, duration: duration, note: note,
                              remember: remember && rememberLabel != nil, context: context)
        timer.refresh()
    }
}
