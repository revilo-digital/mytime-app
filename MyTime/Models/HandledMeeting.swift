import Foundation
import SwiftData

/// A calendar meeting you've added to the timesheet or dismissed, so it isn't suggested again.
///
/// Meetings themselves are read live from your calendars; only this is stored. See `MeetingTracker`.
@Model
final class HandledMeeting {
    /// `CalendarEvent.key`: the event and the occurrence's start.
    var key: String
    /// When the meeting started, so old records can be dropped.
    var at: Date

    init(key: String, at: Date) {
        self.key = key
        self.at = at
    }
}
