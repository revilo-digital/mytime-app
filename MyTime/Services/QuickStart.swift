import Foundation
import SwiftData

/// The popover's one-click Favourites and Recent lists.
enum QuickStart {
    /// Starred tasks, plus one task per starred project (the one last used there, else its first),
    /// sorted by path. `tasks` are the selectable tasks; `entries` are newest first.
    static func favourites(tasks: [TaskType], entries: [TimeEntry]) -> [TaskType] {
        let projects = Set(tasks.compactMap(\.project).filter(\.isFavourite).map(\.persistentModelID))
        var chosen: [PersistentIdentifier: TaskType] = [:]
        for entry in entries {
            guard let task = entry.task, task.isSelectable, let project = task.project,
                  projects.contains(project.persistentModelID), chosen[project.persistentModelID] == nil else { continue }
            chosen[project.persistentModelID] = task
        }
        for task in tasks {
            guard let project = task.project, projects.contains(project.persistentModelID) else { continue }
            if chosen[project.persistentModelID] == nil { chosen[project.persistentModelID] = task }
        }
        var seen = Set<PersistentIdentifier>()
        return (tasks.filter(\.isFavourite) + chosen.values)
            .filter { seen.insert($0.persistentModelID).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The last few tasks tracked, newest first, leaving out ones already in `excluding`.
    static func recents(entries: [TimeEntry], excluding: [TaskType] = [], limit: Int = 3) -> [TaskType] {
        var seen = Set(excluding.map(\.persistentModelID))
        var result: [TaskType] = []
        for entry in entries {
            guard let task = entry.task, task.isSelectable, seen.insert(task.persistentModelID).inserted else { continue }
            result.append(task)
            if result.count == limit { break }
        }
        return result
    }
}
