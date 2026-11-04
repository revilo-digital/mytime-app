import Foundation
import SwiftData
import Testing
@testable import MyTime

@MainActor
struct AwayMonitorTests {
    let container: ModelContainer
    let context: ModelContext
    let task: TaskType
    let defaults: UserDefaults
    /// 9am on a fixed day.
    let morning: Date

    /// Seconds since the last input, as the fake system reports it.
    final class Idle { var seconds: TimeInterval = 0 }
    let idle = Idle()

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        let client = Client(name: "Acme", defaultRate: 150)
        let project = Project(name: "Website", client: client)
        task = TaskType(name: "Development", project: project)
        context.insert(client)
        context.insert(project)
        context.insert(task)
        defaults = UserDefaults(suiteName: "nz.olly.MyTime.away.\(UUID().uuidString)")!
        defaults.set(15, forKey: AwayMonitor.thresholdKey)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        morning = day.addingTimeInterval(9 * 3600)
    }

    private func makeMonitor(_ timer: TimerService, now: Date? = nil) -> (AwayMonitor, () -> [AwayMonitor.Report]) {
        let idle = self.idle
        let monitor = AwayMonitor(timer: timer, defaults: defaults, secondsSinceInput: { idle.seconds }, now: now ?? morning)
        var reports: [AwayMonitor.Report] = []
        monitor.onReturn = { reports.append($0) }
        return (monitor, { reports })
    }

    private func minutes(_ m: Double) -> TimeInterval { m * 60 }

    @Test func longIdleIsReportedFromTheLastInput() throws {
        let timer = TimerService(context: context, defaults: defaults)
        let entry = timer.start(task: task, now: morning)
        let (monitor, reports) = makeMonitor(timer)

        // Last input at 10:00, still nothing at 10:20.
        idle.seconds = minutes(20)
        monitor.poll(now: morning.addingTimeInterval(minutes(80)))
        #expect(monitor.awaySince == morning.addingTimeInterval(minutes(60)))
        #expect(reports().isEmpty)

        // Back at 11:30.
        idle.seconds = 2
        let back = morning.addingTimeInterval(minutes(150))
        monitor.poll(now: back.addingTimeInterval(2))
        #expect(monitor.awaySince == nil)
        let report = try #require(reports().first)
        #expect(report.since == morning.addingTimeInterval(minutes(60)))
        #expect(report.backAt == back)
        #expect(report.stopped.isEmpty)

        // "Remove the Time": the hour before leaving counts, and the timer runs on from 11:30.
        timer.removeAwayTime(since: report.since, backAt: report.backAt, keepRunning: true)
        #expect(entry.isRunning)
        #expect(entry.liveDuration(at: back.addingTimeInterval(minutes(10))) == minutes(70))
    }

    @Test func removeAndStopEndsAtTheMomentYouLeft() {
        let timer = TimerService(context: context, defaults: defaults)
        let entry = timer.start(task: task, now: morning)
        let removed = timer.removeAwayTime(
            since: morning.addingTimeInterval(minutes(30)), backAt: morning.addingTimeInterval(minutes(90)), keepRunning: false
        )
        #expect(!entry.isRunning)
        #expect(!entry.isPaused)
        #expect(entry.durationSeconds == minutes(30))
        #expect(timer.activeEntries.isEmpty)
        #expect(removed.first?.removed == minutes(60))
    }

    @Test func timerStartedWhileAwayIsCutBackToItsOwnStart() {
        let timer = TimerService(context: context, defaults: defaults)
        let entry = timer.start(task: task, now: morning.addingTimeInterval(minutes(40)))
        timer.removeAwayTime(since: morning, backAt: morning.addingTimeInterval(minutes(60)), keepRunning: false)
        #expect(entry.durationSeconds == 0)
    }

    @Test func shortBreaksAndIdleWithoutATimerAreIgnored() {
        let timer = TimerService(context: context, defaults: defaults)
        let (monitor, reports) = makeMonitor(timer)

        // No timer running: nothing to ask about.
        idle.seconds = minutes(60)
        monitor.poll(now: morning)
        #expect(monitor.awaySince == nil)

        // A timer and a 5 minute lock: away, but back before the threshold.
        timer.start(task: task, now: morning)
        idle.seconds = 0
        monitor.poll(now: morning)
        monitor.systemWentAway(now: morning.addingTimeInterval(minutes(10)))
        monitor.systemCameBack()
        idle.seconds = 1
        monitor.poll(now: morning.addingTimeInterval(minutes(15)))
        #expect(monitor.awaySince == nil)
        #expect(reports().isEmpty)
    }

    @Test func sleepCountsAsAwayAndInputWhileLockedIsNotBeingBack() {
        let timer = TimerService(context: context, defaults: defaults)
        timer.start(task: task, now: morning)
        let (monitor, reports) = makeMonitor(timer)

        idle.seconds = 30
        let lockedAt = morning.addingTimeInterval(minutes(60))
        monitor.systemWentAway(now: lockedAt)
        #expect(monitor.awaySince == lockedAt.addingTimeInterval(-30))

        // Mouse moved at the lock screen.
        idle.seconds = 1
        monitor.poll(now: lockedAt.addingTimeInterval(minutes(30)))
        #expect(reports().isEmpty)

        monitor.systemCameBack()
        monitor.poll(now: lockedAt.addingTimeInterval(minutes(40)))
        #expect(reports().count == 1)
    }

    @Test func timerLeftRunningOvernightStopsWhenYouLeft() throws {
        let timer = TimerService(context: context, defaults: defaults)
        let entry = timer.start(task: task, now: morning)
        let (monitor, reports) = makeMonitor(timer)

        // Last input 6pm, the Mac sleeps at 6:20pm and wakes at 8am the next day.
        let left = morning.addingTimeInterval(9 * 3600)
        idle.seconds = minutes(20)
        monitor.systemWentAway(now: left.addingTimeInterval(minutes(20)))
        let nextMorning = morning.addingTimeInterval(23 * 3600)
        monitor.systemCameBack()
        idle.seconds = 0
        monitor.poll(now: nextMorning)

        #expect(!entry.isRunning)
        #expect(entry.durationSeconds == 9 * 3600)
        let report = try #require(reports().first)
        #expect(report.since == left)
        #expect(report.stopped.count == 1)

        // "Keep the Time" puts the night back.
        timer.restoreAwayTime(report.stopped)
        #expect(entry.durationSeconds == 23 * 3600)
    }

    @Test func dayChangeStopsTimersEvenBeforeYouReturn() {
        let timer = TimerService(context: context, defaults: defaults)
        let entry = timer.start(task: task, now: morning)
        let (monitor, reports) = makeMonitor(timer)

        idle.seconds = minutes(30)
        monitor.poll(now: morning.addingTimeInterval(minutes(90)))
        idle.seconds = 16 * 3600
        monitor.poll(now: morning.addingTimeInterval(17 * 3600)) // 2am
        #expect(!entry.isRunning)
        #expect(entry.durationSeconds == minutes(60))
        #expect(reports().isEmpty)

        idle.seconds = 0
        monitor.poll(now: morning.addingTimeInterval(23 * 3600))
        #expect(reports().first?.stopped.count == 1)
    }

    @Test func absenceAcrossARelaunchIsNoticed() {
        let timer = TimerService(context: context, defaults: defaults)
        timer.start(task: task, now: morning)
        let lastSeen = morning.addingTimeInterval(minutes(30))
        defaults.set(lastSeen, forKey: AwayMonitor.lastInputKey)

        let (monitor, _) = makeMonitor(timer, now: morning.addingTimeInterval(minutes(120)))
        #expect(monitor.awaySince == lastSeen)
    }

    @Test func turnedOffNeverReports() {
        defaults.set(0, forKey: AwayMonitor.thresholdKey)
        let timer = TimerService(context: context, defaults: defaults)
        timer.start(task: task, now: morning)
        let (monitor, reports) = makeMonitor(timer)
        idle.seconds = 3 * 3600
        monitor.poll(now: morning.addingTimeInterval(4 * 3600))
        monitor.systemWentAway(now: morning.addingTimeInterval(4 * 3600))
        #expect(monitor.awaySince == nil)
        idle.seconds = 0
        monitor.systemCameBack()
        monitor.poll(now: morning.addingTimeInterval(5 * 3600))
        #expect(reports().isEmpty)
    }
}
