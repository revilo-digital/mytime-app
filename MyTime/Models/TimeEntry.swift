import Foundation
import SwiftData

enum BillingState: String, Codable, CaseIterable {
    /// Not yet dealt with; counts towards Uninvoiced $.
    case unbilled
    /// On an invoice as hourly lines.
    case billed
    /// Closed against an invoice without hourly lines (fixed-fee work).
    case covered
    /// Closed with no invoice.
    case writtenOff
}

/// One block of time on one day.
///
/// `durationSeconds` holds completed time. While the timer runs, `startedAt` is set and
/// `endedAt` is nil; elapsed time is always derived from timestamps, never persisted per tick.
@Model
final class TimeEntry {
    var task: TaskType?
    /// Start of the day this entry belongs to.
    var date: Date
    var durationSeconds: Double
    var startedAt: Date?
    var endedAt: Date?
    var note: String
    var isBillable: Bool
    var billingStateRaw: String
    var invoice: Invoice?
    var writeOffReason: String?
    var createdAt: Date

    var billingState: BillingState {
        get { BillingState(rawValue: billingStateRaw) ?? .unbilled }
        set { billingStateRaw = newValue.rawValue }
    }

    var isRunning: Bool { startedAt != nil && endedAt == nil }

    /// Entries on an invoice or written off can't be edited.
    var isLocked: Bool { billingState != .unbilled }

    func liveDuration(at now: Date = .now) -> TimeInterval {
        guard isRunning, let startedAt else { return durationSeconds }
        return durationSeconds + max(0, now.timeIntervalSince(startedAt))
    }

    init(task: TaskType?, date: Date, durationSeconds: Double = 0, note: String = "") {
        self.task = task
        self.date = Calendar.current.startOfDay(for: date)
        self.durationSeconds = durationSeconds
        self.note = note
        self.isBillable = task?.isBillable ?? true
        self.billingStateRaw = BillingState.unbilled.rawValue
        self.createdAt = .now
    }
}
