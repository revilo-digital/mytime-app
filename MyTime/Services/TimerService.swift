import Foundation
import Observation
import SwiftData

/// Owns the running timers and any paused ones. Only timestamps are persisted; elapsed time is derived.
/// Switching to another task pauses whatever is running; starting one alongside keeps the others going,
/// and each running timer records its full time. Only Stop takes a timer off the Paused list.
@MainActor
@Observable
final class TimerService {
    private let context: ModelContext
    /// Running timers, oldest first.
    private(set) var activeEntries: [TimeEntry] = []
    /// Refreshed every 15s so plain views (like the menu bar label, which can't host
    /// TimelineView) redraw with the current elapsed time.
    private(set) var tick = Date.now
    @ObservationIgnored private var ticker: Timer?

    /// Injected so tests don't overwrite the real app's remembered task.
    @ObservationIgnored private let defaults: UserDefaults

    init(context: ModelContext, defaults: UserDefaults = .standard) {
        self.context = context
        self.defaults = defaults
        recover()
        let ticker = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick = .now }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// Finds timers left running by a previous launch (quit, crash or reboot).
    /// Timers paused on an earlier day are stopped, so the Paused list starts each day empty.
    func recover(now: Date = .now) {
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.startedAt != nil && $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        activeEntries = (try? context.fetch(descriptor)) ?? []
        let today = Calendar.current.startOfDay(for: now)
        let oldPaused = FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.isPaused && $0.date < today })
        for entry in (try? context.fetch(oldPaused)) ?? [] {
            entry.isPaused = false
        }
        save()
    }

    /// Starts timing a task, pausing whatever was running first unless it runs `alongside`. With no note,
    /// today's entry for the same task is picked up again, paused or stopped, rather than starting a second one at zero.
    @discardableResult
    func start(task: TaskType, note: String = "", alongside: Bool = false, now: Date = .now) -> TimeEntry {
        if note.isEmpty, let existing = entryToContinue(for: task, now: now) {
            resume(existing, alongside: alongside, now: now)
            return existing
        }
        if !alongside { pauseAll(now: now) }
        let entry = TimeEntry(task: task, date: now, note: note)
        entry.startedAt = now
        context.insert(entry)
        activeEntries.append(entry)
        remember(task)
        save()
        return entry
    }

    /// Continues an existing unlocked entry, adding time to it, and pauses whatever was running
    /// unless it runs `alongside`.
    func resume(_ entry: TimeEntry, alongside: Bool = false, now: Date = .now) {
        guard !entry.isLocked else { return }
        if !alongside {
            for other in activeEntries where other !== entry { pause(other, now: now) }
        }
        guard !entry.isRunning else { return }
        entry.startedAt = now
        entry.endedAt = nil
        entry.isPaused = false
        activeEntries.append(entry)
        if let task = entry.task { remember(task) }
        save()
    }

    var isRunning: Bool { !activeEntries.isEmpty }

    func stop(_ entry: TimeEntry, now: Date = .now) {
        guard entry.isRunning else { return }
        finish(entry, at: now)
        activeEntries.removeAll { $0 === entry }
        save()
    }

    func stopAll(now: Date = .now) {
        for entry in activeEntries { stop(entry, now: now) }
    }

    /// Banks a running timer's time and parks it on the Paused list.
    func pause(_ entry: TimeEntry, now: Date = .now) {
        guard entry.isRunning else { return }
        finish(entry, at: now)
        entry.isPaused = true
        activeEntries.removeAll { $0 === entry }
        save()
    }

    func pauseAll(now: Date = .now) {
        for entry in activeEntries { pause(entry, now: now) }
    }

    /// Takes a paused timer off the Paused list; its time is already recorded.
    func stopPaused(_ entry: TimeEntry) {
        entry.isPaused = false
        save()
    }

    /// Today's paused timers that can still be picked up, oldest first.
    func pausedEntries(now: Date = .now) -> [TimeEntry] {
        let today = Calendar.current.startOfDay(for: now)
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.isPaused && $0.date == today },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return ((try? context.fetch(descriptor)) ?? []).filter { !$0.isLocked }
    }

    /// Today's unlocked entry for a task: a paused one if there is one, else the most recent.
    private func entryToContinue(for task: TaskType, now: Date) -> TimeEntry? {
        let today = Calendar.current.startOfDay(for: now)
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.date == today },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let matching = ((try? context.fetch(descriptor)) ?? []).filter {
            !$0.isLocked && $0.task?.persistentModelID == task.persistentModelID
        }
        return matching.first(where: \.isPaused) ?? matching.first
    }

    /// Everything tracked today, including the running entry.
    func todayTotal(at now: Date = .now) -> TimeInterval {
        let today = Calendar.current.startOfDay(for: now)
        let descriptor = FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.date == today })
        return ((try? context.fetch(descriptor)) ?? []).reduce(0) { $0 + $1.liveDuration(at: now) }
    }

    /// Redraws the menu bar time now, e.g. after a running entry was edited.
    func refresh() { tick = .now }

    /// Discards a running entry entirely.
    func cancel(_ entry: TimeEntry) {
        guard entry.isRunning else { return }
        activeEntries.removeAll { $0 === entry }
        context.delete(entry)
        save()
    }

    /// Global-hotkey behaviour: stop everything running, otherwise restart the last-used task.
    func toggleLast(now: Date = .now) {
        if isRunning {
            stopAll(now: now)
        } else if let task = lastUsedTask() {
            start(task: task, now: now)
        }
    }

    /// The task remembered by the popover, else the most recently tracked one.
    func lastUsedTask() -> TaskType? {
        if let idString = defaults.string(forKey: Self.lastTaskKey), let id = UUID(uuidString: idString) {
            let descriptor = FetchDescriptor<TaskType>(predicate: #Predicate { $0.uuid == id })
            if let task = try? context.fetch(descriptor).first, task.isSelectable { return task }
        }
        var descriptor = FetchDescriptor<TimeEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 20
        let recent = (try? context.fetch(descriptor)) ?? []
        return recent.compactMap(\.task).first(where: \.isSelectable)
    }

    static let lastTaskKey = "lastTaskID"

    /// Remembers the task for the popover's pickers and the start/stop hotkey.
    func remember(_ task: TaskType) {
        defaults.set(task.uuid.uuidString, forKey: Self.lastTaskKey)
    }

    private func finish(_ entry: TimeEntry, at now: Date) {
        entry.durationSeconds = entry.liveDuration(at: now)
        entry.endedAt = now
        entry.isPaused = false
    }

    private func save() {
        do { try context.save() } catch { print("MyTime save failed: \(error)") }
    }
}
