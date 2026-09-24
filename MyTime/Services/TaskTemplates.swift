import Foundation
import SwiftData

/// Applies the default task list to projects, and tidies up old tasks.
@MainActor
enum TaskTemplates {
    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// A new project with every default task.
    @discardableResult
    static func makeProject(name: String = "New Project", client: Client, settings: BusinessSettings,
                            context: ModelContext) -> Project {
        let project = Project(name: name, client: client)
        context.insert(project)
        addMissingDefaults(to: project, settings: settings, context: context)
        try? context.save()
        return project
    }

    /// Adds default tasks the project lacks (matching names case-insensitively) and unarchives
    /// any that were archived. Returns how many tasks were added or restored.
    @discardableResult
    static func addMissingDefaults(to project: Project, settings: BusinessSettings, context: ModelContext) -> Int {
        var changed = 0
        for template in settings.defaultTasks {
            if let existing = project.tasks.first(where: { key($0.name) == key(template.name) }) {
                if existing.isArchived { existing.isArchived = false; changed += 1 }
                continue
            }
            let task = TaskType(name: template.name, project: project)
            task.isBillable = template.isBillable
            context.insert(task)
            changed += 1
        }
        return changed
    }

    /// Archives tasks that aren't on the default list. Their time is kept.
    @discardableResult
    static func archiveNonDefaults(in project: Project, settings: BusinessSettings) -> Int {
        let names = Set(settings.defaultTasks.map { key($0.name) })
        var archived = 0
        for task in project.tasks where !task.isArchived && !names.contains(key(task.name)) {
            task.isArchived = true
            archived += 1
        }
        return archived
    }

    /// Runs `addMissingDefaults` (and optionally `archiveNonDefaults`) on every unarchived project.
    static func applyToAllProjects(archiveOthers: Bool, settings: BusinessSettings,
                                   context: ModelContext) -> (added: Int, archived: Int, projects: Int) {
        let projects = ((try? context.fetch(FetchDescriptor<Project>())) ?? []).filter { !$0.isArchived }
        var added = 0, archived = 0
        for project in projects {
            added += addMissingDefaults(to: project, settings: settings, context: context)
            if archiveOthers { archived += archiveNonDefaults(in: project, settings: settings) }
        }
        try? context.save()
        return (added, archived, projects.count)
    }

    /// Moves every entry from `source` to `target` (same project), then deletes `source`.
    /// Invoices keep their snapshot lines, so billed time can be moved safely.
    static func merge(_ source: TaskType, into target: TaskType, context: ModelContext) {
        guard source.persistentModelID != target.persistentModelID else { return }
        for entry in source.entries {
            entry.task = target
        }
        context.delete(source)
        try? context.save()
    }
}
