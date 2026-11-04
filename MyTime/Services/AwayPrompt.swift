import AppKit

/// The "you were away" question shown when you come back to the Mac with a timer involved.
@MainActor
enum AwayPrompt {
    private static var isShowing = false

    static func present(_ report: AwayMonitor.Report, timer: TimerService) {
        guard !isShowing else { return }
        isShowing = true
        defer { isShowing = false }

        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil)
        let away = DurationFormat.short(report.backAt.timeIntervalSince(report.since))
        let left = time(report.since, relativeTo: report.backAt)

        NSApp.activate()
        if !report.stopped.isEmpty {
            alert.messageText = "Your timer was stopped while you were away"
            alert.informativeText = "\(names(report.stopped.map(\.entry))) stopped at \(left), when you left. "
                + "The \(away) since then isn't counted."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Keep the Time")
            if alert.runModal() == .alertSecondButtonReturn {
                timer.restoreAwayTime(report.stopped)
            }
            return
        }

        alert.messageText = "You were away for \(away)"
        alert.informativeText = "From \(left) to \(time(report.backAt, relativeTo: report.backAt)), "
            + "while \(names(timer.activeEntries)) was running."
        alert.addButton(withTitle: "Remove the Time")
        alert.addButton(withTitle: "Remove and Stop")
        alert.addButton(withTitle: "Keep the Time")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            timer.removeAwayTime(since: report.since, backAt: report.backAt, keepRunning: true)
        case .alertSecondButtonReturn:
            timer.removeAwayTime(since: report.since, backAt: report.backAt, keepRunning: false)
        default:
            break
        }
        timer.refresh()
    }

    private static func names(_ entries: [TimeEntry]) -> String {
        let names = entries.map { $0.task?.shortPath ?? "Your timer" }
        return names.isEmpty ? "your timer" : ListFormatter.localizedString(byJoining: names)
    }

    /// "6:42 pm", or "6:42 pm yesterday" / "6:42 pm on Mon 2 Nov" when it was an earlier day.
    private static func time(_ date: Date, relativeTo now: Date) -> String {
        let clock = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "\(clock) yesterday"
        }
        return "\(clock) on \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
    }
}
