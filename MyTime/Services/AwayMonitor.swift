import AppKit
import CoreGraphics
import Foundation

/// Notices when you step away from the Mac while a timer runs, and asks about that time when you're back.
///
/// You're away once there's been no keyboard, mouse or trackpad input for the threshold, or from the moment
/// the Mac sleeps or the screen locks. If the day changes while you're away, the running timers are stopped
/// at the moment you left, so a timer left on overnight never collects the night.
@MainActor
final class AwayMonitor {
    /// Minutes without input before you count as away; 0 turns this off.
    static let thresholdKey = "idleThresholdMinutes"
    static let defaultThresholdMinutes = 15
    static let thresholdChoices = [0, 5, 10, 15, 30, 60]
    /// Last time input was seen, so an absence spanning a quit, crash or restart is still noticed.
    static let lastInputKey = "lastInputAt"
    /// Input this recent means you're back.
    static let returnWindow: TimeInterval = 10

    struct Report {
        let since: Date
        let backAt: Date
        /// Timers stopped because the day changed while you were away, with the time left out of each.
        let stopped: [(entry: TimeEntry, removed: TimeInterval)]
    }

    private let timer: TimerService
    private let defaults: UserDefaults
    private let secondsSinceInput: () -> TimeInterval
    /// When the time away began; nil while you're at the Mac.
    private(set) var awaySince: Date?
    private var stopped: [(entry: TimeEntry, removed: TimeInterval)] = []
    /// Asleep or locked: input (a cat on the keyboard at the lock screen) doesn't count as being back.
    private var isSuspended = false
    /// Called when you're back after long enough away with a timer involved.
    var onReturn: ((Report) -> Void)?

    private var poller: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        timer: TimerService,
        defaults: UserDefaults = .standard,
        secondsSinceInput: @escaping () -> TimeInterval = AwayMonitor.systemSecondsSinceInput,
        now: Date = .now
    ) {
        self.timer = timer
        self.defaults = defaults
        self.secondsSinceInput = secondsSinceInput
        // A timer still running from before a quit or restart: you've been away since the last input seen.
        if let threshold, timer.isRunning,
           let last = defaults.object(forKey: Self.lastInputKey) as? Date,
           now.timeIntervalSince(last) >= threshold {
            awaySince = last
        }
    }

    var threshold: TimeInterval? {
        let minutes = defaults.object(forKey: Self.thresholdKey) as? Int ?? Self.defaultThresholdMinutes
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    /// Checks for input every few seconds and listens for sleep, wake, lock and unlock.
    func start() {
        let poller = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(poller, forMode: .common)
        self.poller = poller

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { $0.systemWentAway() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { $0.systemCameBack() }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.systemWentAway() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.systemCameBack() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor @Sendable (AwayMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    func poll(now: Date = .now) {
        guard let threshold else {
            awaySince = nil
            stopped = []
            return
        }
        let idle = secondsSinceInput()
        let lastInput = now.addingTimeInterval(-idle)

        guard let since = awaySince else {
            if idle >= threshold, timer.isRunning {
                awaySince = lastInput
            } else if !isSuspended {
                defaults.set(lastInput, forKey: Self.lastInputKey)
            }
            return
        }

        // The day changed while you were away: stop the timers at the moment you left.
        if timer.isRunning, !Calendar.current.isDate(since, inSameDayAs: now) {
            stopped += timer.removeAwayTime(since: since, backAt: now, keepRunning: false)
        }
        guard !isSuspended, idle < Self.returnWindow else { return }

        awaySince = nil
        defaults.set(lastInput, forKey: Self.lastInputKey)
        let report = Report(since: since, backAt: lastInput, stopped: stopped)
        stopped = []
        if lastInput.timeIntervalSince(since) >= threshold, timer.isRunning || !report.stopped.isEmpty {
            onReturn?(report)
        }
    }

    /// Sleep, screen sleep, lock or a switch to another user: you're away from your last input.
    func systemWentAway(now: Date = .now) {
        if awaySince == nil, threshold != nil, timer.isRunning {
            awaySince = now.addingTimeInterval(-secondsSinceInput())
        }
        isSuspended = true
    }

    /// Wake or unlock; the next input after this counts as being back.
    func systemCameBack() {
        isSuspended = false
    }

    /// Seconds since the last keyboard, mouse or trackpad input in this login session. Needs no permissions.
    nonisolated static func systemSecondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
