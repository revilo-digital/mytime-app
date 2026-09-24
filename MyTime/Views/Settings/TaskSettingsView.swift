import SwiftData
import SwiftUI

/// Edits the default task list and applies it to existing projects.
struct TaskSettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var tasks: [DefaultTask] = []
    @State private var confirmApply = false
    @State private var archiveOthers = true
    @State private var result: String?

    private var settings: BusinessSettings { BusinessSettings.current(in: context) }

    var body: some View {
        Form {
            Section {
                ForEach($tasks) { $task in
                    HStack {
                        TextField("Task name", text: $task.name).labelsHidden()
                        Toggle("Billable", isOn: $task.isBillable).toggleStyle(.checkbox)
                        Button { tasks.removeAll { $0.id == task.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove from the default list (existing projects keep it)")
                    }
                }
                .onMove { tasks.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    Button("Add Task", systemImage: "plus") { tasks.append(DefaultTask(name: "\(tasks.count + 1). ")) }
                    Spacer()
                    Button("Reset to Recommended") { tasks = DefaultTask.recommended }
                        .disabled(tasks.map(\.name) == DefaultTask.recommended.map(\.name))
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Default tasks")
            } footer: {
                Text("Every new project gets these. Tasks describe the kind of work — put specifics like tools or tickets in the entry's note. Numbers keep them in order in pickers and on invoices.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Also archive tasks that aren't on the list", isOn: $archiveOthers)
                HStack {
                    Button("Apply to All Projects…") { confirmApply = true }
                    if let result {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Existing projects")
            } footer: {
                Text("Adds any missing default tasks to every active project. Archived tasks keep their time and invoices; move time onto a default task with Merge Into in the project editor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { tasks = settings.defaultTasks }
        .onChange(of: tasks) {
            settings.defaultTasks = tasks.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            try? context.save()
        }
        .confirmationDialog("Apply the default tasks to all projects?", isPresented: $confirmApply) {
            Button("Apply") {
                let outcome = TaskTemplates.applyToAllProjects(archiveOthers: archiveOthers, settings: settings, context: context)
                result = "\(outcome.added) added" + (archiveOthers ? ", \(outcome.archived) archived" : "")
                    + " across \(outcome.projects) project\(outcome.projects == 1 ? "" : "s")"
            }
        } message: {
            Text(archiveOthers
                 ? "Missing default tasks are added, and other tasks are archived (their time is kept)."
                 : "Missing default tasks are added. Other tasks are left alone.")
        }
    }
}
