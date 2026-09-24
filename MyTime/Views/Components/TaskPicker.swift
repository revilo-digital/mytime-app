import SwiftData
import SwiftUI

/// Two dropdowns: project (labelled "Client › Project") then that project's tasks.
/// Only projects and tasks a timer can be started on are offered, plus the current selection.
/// In a Form each dropdown gets its own labelled row; elsewhere they stack.
struct TaskPicker: View {
    @Binding var selection: TaskType?
    var placeholder = "Choose a project…"

    @Query(filter: #Predicate<TaskType> { !$0.isArchived })
    private var allTasks: [TaskType]

    @State private var project: Project?

    private var currentID: PersistentIdentifier? { selection?.persistentModelID }

    private var usableTasks: [TaskType] {
        allTasks.filter { $0.isSelectable || $0.persistentModelID == currentID }
    }

    private var projects: [Project] {
        var seen = Set<PersistentIdentifier>()
        var result = usableTasks.compactMap(\.project).filter { seen.insert($0.persistentModelID).inserted }
        if let project, !seen.contains(project.persistentModelID) { result.append(project) }
        return result.sorted { Self.title($0).localizedStandardCompare(Self.title($1)) == .orderedAscending }
    }

    private var tasks: [TaskType] {
        guard let project else { return [] }
        return usableTasks
            .filter { $0.project?.persistentModelID == project.persistentModelID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func title(_ project: Project) -> String {
        [project.client?.name, project.name].compactMap { $0 }.joined(separator: " › ")
    }

    var body: some View {
        Group {
            Picker("Project", selection: Binding(get: { project }, set: choose)) {
                Text(placeholder).tag(Project?.none)
                ForEach(projects) { Text(Self.title($0)).tag(Optional($0)) }
            }
            Picker("Task", selection: $selection) {
                Text(project == nil ? "Choose a project first" : "Choose a task…").tag(TaskType?.none)
                ForEach(tasks) { Text($0.name).tag(Optional($0)) }
            }
            .disabled(project == nil)
        }
        .onAppear { project = selection?.project }
        .onChange(of: currentID) {
            // Keep the project in step when the task is set from elsewhere (favourites, recents).
            if let selected = selection?.project, selected.persistentModelID != project?.persistentModelID {
                project = selected
            }
        }
    }

    /// Switching project keeps the same-named task (default tasks are shared), else the
    /// project's most recently used task, else its first task.
    private func choose(_ newProject: Project?) {
        let previousName = selection?.name
        project = newProject
        guard let newProject else { selection = nil; return }
        let candidates = usableTasks
            .filter { $0.project?.persistentModelID == newProject.persistentModelID && $0.isSelectable }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let recent = candidates.max {
            ($0.entries.map(\.createdAt).max() ?? .distantPast) < ($1.entries.map(\.createdAt).max() ?? .distantPast)
        }
        selection = candidates.first { $0.name.caseInsensitiveCompare(previousName ?? "") == .orderedSame }
            ?? (recent?.entries.isEmpty == false ? recent : nil)
            ?? candidates.first
    }
}
