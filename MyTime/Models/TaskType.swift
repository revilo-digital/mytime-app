import Foundation
import SwiftData

/// A Harvest-style task (e.g. "Development", "Meetings"). Named TaskType to avoid clashing with Swift's `Task`.
@Model
final class TaskType {
    /// Stable identifier for preferences like "last used task".
    var uuid: UUID
    var project: Project?
    var name: String
    var rateOverride: Decimal?
    var isBillable: Bool
    var isArchived: Bool
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \TimeEntry.task)
    var entries: [TimeEntry] = []

    /// "Client / Project / Task" for pickers and labels.
    var path: String {
        [project?.client?.name, project?.name, name].compactMap { $0 }.joined(separator: " / ")
    }

    /// "Project / Task", for lists already grouped by client.
    var shortPath: String {
        [project?.name, name].compactMap { $0 }.joined(separator: " / ")
    }

    /// Can a timer be started on this task?
    var isSelectable: Bool {
        !isArchived && project?.isArchived == false && project?.client?.isArchived == false
    }

    init(name: String, project: Project) {
        self.uuid = UUID()
        self.project = project
        self.name = name
        self.isBillable = true
        self.isArchived = false
        self.createdAt = .now
    }
}
