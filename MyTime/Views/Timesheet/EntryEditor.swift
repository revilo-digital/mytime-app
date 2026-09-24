import SwiftData
import SwiftUI

struct EntryEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let target: EntryEditTarget
    let timer: TimerService

    @State private var task: TaskType?
    @State private var date = Date.now
    @State private var durationText = ""
    @State private var note = ""
    @State private var isBillable = true
    @State private var loaded = false
    @State private var confirmDelete = false

    private var existing: TimeEntry? {
        if case .existing(let entry) = target { entry } else { nil }
    }

    private var isLocked: Bool { existing?.isLocked ?? false }
    private var isRunning: Bool { existing?.isRunning ?? false }
    private var parsedDuration: TimeInterval? { DurationFormat.parse(durationText) }

    /// A new entry with no duration on today starts a timer, like Harvest.
    private var startsTimer: Bool {
        existing == nil && durationText.trimmingCharacters(in: .whitespaces).isEmpty && Calendar.current.isDateInToday(date)
    }

    private var canSave: Bool {
        guard task != nil, !isLocked else { return false }
        return startsTimer || isRunning || parsedDuration != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isLocked {
                    Label("This entry is on an invoice or written off, so it can't be edited.", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
                TaskPicker(selection: $task)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                if isRunning {
                    LabeledContent("Duration") {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(DurationFormat.clock(existing?.liveDuration(at: ctx.date) ?? 0)).monospacedDigit()
                        }
                    }
                } else {
                    TextField("Duration", text: $durationText, prompt: Text(existing == nil ? "0:00 — blank starts a timer" : "0:00"))
                    if !durationText.isEmpty && parsedDuration == nil {
                        Text("Try 1:30, 1.5 or 90m").font(.caption).foregroundStyle(.red)
                    }
                }
                TextField("Note", text: $note, axis: .vertical).lineLimit(2...6)
                Toggle("Billable", isOn: $isBillable)
                    .disabled(!RateResolver.isBillable(task))
                if let task, RateResolver.isBillable(task), isBillable, task.project?.billingType == .hourly, let seconds = parsedDuration {
                    LabeledContent("Value") {
                        Text("\(Money.format(Money.round(DurationFormat.hours(seconds) * RateResolver.rate(for: task)))) at \(Money.format(RateResolver.rate(for: task)))/h")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isLocked)

            HStack {
                if let existing, !isLocked {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .confirmationDialog("Delete this entry?", isPresented: $confirmDelete) {
                        Button("Delete", role: .destructive) {
                            if existing.isRunning { timer.cancel() } else { context.delete(existing); try? context.save() }
                            dismiss()
                        }
                    } message: {
                        Text("\(existing.task?.shortPath ?? "Entry") · \(DurationFormat.short(existing.liveDuration())). This can't be undone.")
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(startsTimer ? "Start Timer" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 460)
        .onAppear(perform: load)
        .onChange(of: task) { _, newTask in
            if loaded, existing == nil { isBillable = RateResolver.isBillable(newTask) }
        }
    }

    private func load() {
        switch target {
        case .new(let day, let preset):
            date = day
            task = preset
            isBillable = true
        case .existing(let entry):
            task = entry.task
            date = entry.date
            durationText = DurationFormat.short(entry.liveDuration())
            note = entry.note
            isBillable = entry.isBillable
        }
        DispatchQueue.main.async { loaded = true }
    }

    private func save() {
        guard let task else { return }
        if let entry = existing {
            entry.task = task
            entry.date = Calendar.current.startOfDay(for: date)
            entry.note = note
            entry.isBillable = isBillable
            if !entry.isRunning, let seconds = parsedDuration {
                // Only overwrite if the user changed it, so seconds aren't lost to h:mm display rounding.
                if durationText != DurationFormat.short(entry.durationSeconds) { entry.durationSeconds = seconds }
            }
            try? context.save()
        } else if startsTimer {
            let entry = timer.start(task: task, note: note)
            entry.isBillable = isBillable
        } else if let seconds = parsedDuration {
            let entry = TimeEntry(task: task, date: date, durationSeconds: seconds, note: note)
            entry.isBillable = isBillable
            context.insert(entry)
            try? context.save()
        }
        dismiss()
    }
}
