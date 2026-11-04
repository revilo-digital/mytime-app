import Foundation
import SwiftData
import Testing
@testable import MyTime

@MainActor
struct TimerServiceTests {
    let container: ModelContainer
    let context: ModelContext
    let task: TaskType
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        let client = Client(name: "Acme", defaultRate: 150)
        let project = Project(name: "Website", client: client)
        task = TaskType(name: "Development", project: project)
        context.insert(client)
        context.insert(project)
        context.insert(task)
    }

    private func allEntries() throws -> [TimeEntry] {
        try context.fetch(FetchDescriptor<TimeEntry>())
    }

    @Test func resumeRemembersTaskAndMissingTaskFallsBackToRecent() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let other = TaskType(name: "Meetings", project: task.project!)
        context.insert(other)
        let entry = timer.start(task: other, now: t0)
        timer.stop(entry, now: t0.addingTimeInterval(600))
        timer.remember(task)
        timer.resume(entry, now: t0.addingTimeInterval(700))
        #expect(timer.lastUsedTask()?.name == "Meetings")

        // A remembered task that no longer exists falls back to the most recent entry's task.
        UserDefaults.tests.set(UUID().uuidString, forKey: TimerService.lastTaskKey)
        #expect(timer.lastUsedTask()?.name == "Meetings")
    }

    @Test func startPersistsTimestampOnly() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: task, note: "Homepage", now: t0)
        #expect(entry.isRunning)
        #expect(entry.startedAt == t0)
        #expect(entry.durationSeconds == 0)
        #expect(entry.liveDuration(at: t0.addingTimeInterval(90)) == 90)
    }

    @Test func stopRecordsDuration() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: task, now: t0)
        timer.stop(entry, now: t0.addingTimeInterval(3600))
        #expect(!entry.isRunning)
        #expect(entry.durationSeconds == 3600)
        #expect(timer.activeEntries.isEmpty)
    }

    @Test func startingAnotherTaskPausesTheFirst() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let other = TaskType(name: "Meetings", project: task.project!)
        context.insert(other)
        let first = timer.start(task: task, now: t0)
        let second = timer.start(task: other, now: t0.addingTimeInterval(600))
        #expect(first.durationSeconds == 600)
        #expect(!first.isRunning)
        #expect(first.isPaused)
        #expect(second.isRunning)
        #expect(try allEntries().filter(\.isRunning).count == 1)
    }

    @Test func recoversRunningTimerAfterRelaunch() throws {
        let first = TimerService(context: context, defaults: .tests)
        let entry = first.start(task: task, now: t0)
        // Simulate a relaunch: a fresh service over the same store.
        let relaunched = TimerService(context: context, defaults: .tests)
        #expect(relaunched.activeEntries.map(\.persistentModelID) == [entry.persistentModelID])
        // Sleep or downtime is counted because elapsed derives from startedAt.
        #expect(relaunched.activeEntries.first?.liveDuration(at: t0.addingTimeInterval(7200)) == 7200)
    }

    @Test func recoveryKeepsEveryRunningEntry() throws {
        for offset in [60.0, 0] {
            let e = TimeEntry(task: task, date: t0)
            e.startedAt = t0.addingTimeInterval(offset)
            context.insert(e)
        }
        let timer = TimerService(context: context, defaults: .tests)
        timer.recover(now: t0.addingTimeInterval(120))
        #expect(try allEntries().filter(\.isRunning).count == 2)
        #expect(timer.activeEntries.map(\.startedAt) == [t0, t0.addingTimeInterval(60)])
    }

    @Test func resumeAddsToExistingDuration() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: task, now: t0)
        timer.stop(entry, now: t0.addingTimeInterval(1800))
        timer.resume(entry, now: t0.addingTimeInterval(3600))
        timer.stop(entry, now: t0.addingTimeInterval(4500))
        #expect(entry.durationSeconds == 2700)
    }

    @Test func lockedEntriesCannotResume() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: task, now: t0)
        timer.stop(entry, now: t0.addingTimeInterval(60))
        entry.billingState = .billed
        timer.resume(entry, now: t0.addingTimeInterval(120))
        #expect(!entry.isRunning)
    }

    @Test func cancelDeletesTheEntry() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: task, now: t0)
        timer.cancel(entry)
        #expect(try allEntries().isEmpty)
        #expect(timer.activeEntries.isEmpty)
    }
}

extension TimerServiceTests {
    @Test func toggleLastStopsThenRestartsLastTask() throws {
        let timer = TimerService(context: context, defaults: .tests)
        timer.start(task: task, now: t0)
        timer.toggleLast(now: t0.addingTimeInterval(60))
        #expect(timer.activeEntries.isEmpty)
        timer.toggleLast(now: t0.addingTimeInterval(120))
        #expect(timer.activeEntries.first?.task?.persistentModelID == task.persistentModelID)
        #expect(try allEntries().count == 1)
    }
}

extension TimerServiceTests {
    @Test func pauseBanksTimeAndListsTheTimer() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: task, now: t0)
        timer.pause(entry, now: t0.addingTimeInterval(900))
        #expect(timer.activeEntries.isEmpty)
        #expect(!entry.isRunning)
        #expect(entry.durationSeconds == 900)
        #expect(timer.pausedEntries(now: t0).map(\.persistentModelID) == [entry.persistentModelID])
    }

    @Test func startingAPausedTaskPicksUpTheSameEntry() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: task, now: t0)
        timer.pause(entry, now: t0.addingTimeInterval(600))
        let again = timer.start(task: task, now: t0.addingTimeInterval(1200))
        #expect(again.persistentModelID == entry.persistentModelID)
        timer.stop(entry, now: t0.addingTimeInterval(1500))
        #expect(entry.durationSeconds == 900)
        #expect(!entry.isPaused)
        #expect(try allEntries().count == 1)
    }

    @Test func startingAStoppedTaskAddsToTheSameEntry() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: task, now: t0)
        timer.stop(entry, now: t0.addingTimeInterval(600))
        let again = timer.start(task: task, now: t0.addingTimeInterval(1200))
        #expect(again.persistentModelID == entry.persistentModelID)
        #expect(again.isRunning)
        timer.stop(entry, now: t0.addingTimeInterval(1500))
        #expect(entry.durationSeconds == 900)
        #expect(try allEntries().count == 1)
    }

    @Test func startingAfterALockedEntryOrOnANewDayMakesANewEntry() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let locked = timer.start(task: task, now: t0)
        timer.stop(locked, now: t0.addingTimeInterval(600))
        locked.billingState = .billed
        let unlocked = timer.start(task: task, now: t0.addingTimeInterval(1200))
        #expect(unlocked.persistentModelID != locked.persistentModelID)
        timer.stop(unlocked, now: t0.addingTimeInterval(1800))
        let tomorrow = timer.start(task: task, now: t0.addingTimeInterval(86_400))
        #expect(tomorrow.persistentModelID != unlocked.persistentModelID)
        #expect(tomorrow.durationSeconds == 0)
    }

    @Test func startingPrefersThePausedEntryOverALaterStoppedOne() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let paused = timer.start(task: task, now: t0)
        timer.pause(paused, now: t0.addingTimeInterval(600))
        let other = timer.start(task: task, note: "Something else", now: t0.addingTimeInterval(700))
        timer.stop(other, now: t0.addingTimeInterval(800))
        #expect(timer.start(task: task, now: t0.addingTimeInterval(900)).persistentModelID == paused.persistentModelID)
    }

    @Test func startingWithANoteMakesANewEntryEvenIfPaused() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: task, now: t0)
        timer.pause(entry, now: t0.addingTimeInterval(600))
        timer.start(task: task, note: "Something else", now: t0.addingTimeInterval(700))
        #expect(try allEntries().count == 2)
    }

    @Test func switchingBetweenPausedTimersKeepsBothOpen() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let other = TaskType(name: "Meetings", project: task.project!)
        context.insert(other)
        let a = timer.start(task: task, now: t0)
        let b = timer.start(task: other, now: t0.addingTimeInterval(600))
        timer.resume(a, now: t0.addingTimeInterval(900))
        #expect(a.isRunning && !a.isPaused)
        #expect(b.isPaused && b.durationSeconds == 300)
        timer.resume(b, now: t0.addingTimeInterval(1200))
        #expect(a.isPaused && a.durationSeconds == 900)
        #expect(timer.pausedEntries(now: t0).count == 1)
        #expect(try allEntries().count == 2)
    }

    @Test func stoppingAPausedTimerKeepsItsTime() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: task, now: t0)
        timer.pause(entry, now: t0.addingTimeInterval(600))
        timer.stopPaused(entry)
        #expect(!entry.isPaused)
        #expect(entry.durationSeconds == 600)
        #expect(timer.pausedEntries(now: t0).isEmpty)
    }

    @Test func lockedPausedTimersDropOffTheList() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: task, now: t0)
        timer.pause(entry, now: t0.addingTimeInterval(600))
        entry.billingState = .billed
        #expect(timer.pausedEntries(now: t0).isEmpty)
    }

    @Test func recoveryStopsTimersPausedOnEarlierDays() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: task, now: t0)
        timer.pause(entry, now: t0.addingTimeInterval(600))
        timer.recover(now: t0.addingTimeInterval(86_400))
        #expect(!entry.isPaused)
        #expect(entry.durationSeconds == 600)
    }
}

extension TimerServiceTests {
    private func otherTask() -> TaskType {
        let other = TaskType(name: "Meetings", project: task.project!)
        context.insert(other)
        return other
    }

    @Test func alongsideTimersEachRecordTheirFullTime() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let a = timer.start(task: task, now: t0)
        let b = timer.start(task: otherTask(), alongside: true, now: t0.addingTimeInterval(600))
        #expect(a.isRunning && b.isRunning)
        #expect(timer.activeEntries.map(\.persistentModelID) == [a.persistentModelID, b.persistentModelID])
        timer.stop(a, now: t0.addingTimeInterval(3600))
        #expect(a.durationSeconds == 3600)
        #expect(b.isRunning)
        timer.stop(b, now: t0.addingTimeInterval(4200))
        #expect(b.durationSeconds == 3600)
        #expect(timer.todayTotal(at: t0.addingTimeInterval(4200)) == 7200)
    }

    @Test func switchingPausesEveryRunningTimer() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let a = timer.start(task: task, now: t0)
        let b = timer.start(task: otherTask(), alongside: true, now: t0)
        let third = TaskType(name: "Admin", project: task.project!)
        context.insert(third)
        let c = timer.start(task: third, now: t0.addingTimeInterval(600))
        #expect(a.isPaused && b.isPaused)
        #expect(timer.activeEntries.map(\.persistentModelID) == [c.persistentModelID])
    }

    @Test func switchingToAnAlreadyRunningTaskPausesTheOthers() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let a = timer.start(task: task, now: t0)
        let b = timer.start(task: otherTask(), alongside: true, now: t0)
        timer.resume(a, now: t0.addingTimeInterval(300))
        #expect(a.isRunning && a.startedAt == t0)
        #expect(b.isPaused && b.durationSeconds == 300)
    }

    @Test func resumingAPausedTimerAlongsideKeepsTheRunningOne() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let a = timer.start(task: task, now: t0)
        timer.pause(a, now: t0.addingTimeInterval(600))
        let b = timer.start(task: otherTask(), now: t0.addingTimeInterval(600))
        timer.resume(a, alongside: true, now: t0.addingTimeInterval(900))
        #expect(a.isRunning && !a.isPaused && b.isRunning)
        #expect(timer.pausedEntries(now: t0).isEmpty)
    }

    @Test func pausingOneAlongsideTimerLeavesTheOtherRunning() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let a = timer.start(task: task, now: t0)
        let b = timer.start(task: otherTask(), alongside: true, now: t0)
        timer.pause(b, now: t0.addingTimeInterval(600))
        #expect(a.isRunning)
        #expect(b.isPaused && b.durationSeconds == 600)
        timer.cancel(a)
        #expect(timer.activeEntries.isEmpty)
        #expect(try allEntries().count == 1)
    }

    @Test func toggleLastStopsEveryRunningTimer() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let a = timer.start(task: task, now: t0)
        let b = timer.start(task: otherTask(), alongside: true, now: t0)
        timer.toggleLast(now: t0.addingTimeInterval(60))
        #expect(!a.isRunning && !b.isRunning && !a.isPaused && !b.isPaused)
        #expect(timer.activeEntries.isEmpty)
    }

    @Test func menuBarShowsEachRunningTimerNewestFirst() throws {
        let timer = TimerService(context: context, defaults: .tests)
        timer.start(task: task, now: t0)
        timer.start(task: otherTask(), alongside: true, now: t0.addingTimeInterval(3600))
        let now = t0.addingTimeInterval(3600 + 900)
        #expect(MenuBarLabel.runningText(timer.activeEntries, at: now) == "0:15 · 1:15")
        let third = TaskType(name: "Admin", project: task.project!)
        context.insert(third)
        timer.start(task: third, alongside: true, now: now)
        #expect(MenuBarLabel.runningText(timer.activeEntries, at: now) == "0:00 +2")
    }
}

extension UserDefaults {
    /// Separate domain so tests never touch the real app's preferences.
    nonisolated(unsafe) static let tests = UserDefaults(suiteName: "nz.olly.MyTime.tests")!
}
