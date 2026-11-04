import Foundation
import SwiftData

/// A sign that an AI coding tool (Claude Code, Cursor) was working in a folder at a moment.
///
/// Beats are grouped into blocks of work and offered on the timesheet as suggestions; accepting or
/// dismissing a suggestion deletes its beats. See `ActivityTracker`.
@Model
final class ActivityBeat {
    var at: Date
    /// Repository root (or working folder outside a repository), standardised.
    var folder: String
    /// "claude", "cursor", …
    var source: String

    init(at: Date, folder: String, source: String) {
        self.at = at
        self.folder = folder
        self.source = source
    }
}

/// A short label an AI tool logged for its work in a folder ("Invoice layout"), with an optional estimate
/// for time MyTime didn't measure. Joins that day's suggestion for the folder's project.
@Model
final class ActivityNote {
    var at: Date
    var folder: String
    var source: String
    /// One to three words, as it may appear on an invoice.
    var text: String
    /// The tool's estimate, used only when no activity was measured; 0 for none.
    var estimateSeconds: Double = 0

    init(at: Date, folder: String, source: String, text: String, estimateSeconds: Double = 0) {
        self.at = at
        self.folder = folder
        self.source = source
        self.text = text
        self.estimateSeconds = estimateSeconds
    }
}
