import SwiftData
import SwiftUI

struct ProjectEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var project: Project

    private var tasks: [TaskType] {
        project.tasks.sorted {
            if $0.isArchived != $1.isArchived { return !$0.isArchived }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Project") {
                    TextField("Name", text: $project.name)
                    TextField("Code", text: $project.code, prompt: Text("Optional"))
                    Picker("Billing", selection: $project.billingType) {
                        Text("Hourly").tag(BillingType.hourly)
                        Text("Fixed fee").tag(BillingType.fixedFee)
                    }
                    .pickerStyle(.segmented)
                    if project.billingType == .fixedFee {
                        OptionalDecimalField(title: "Agreed fee", value: $project.fixedFee, prompt: "Optional budget")
                        Text("Time on fixed-fee projects is tracked but never counts as uninvoiced.")
                            .font(.caption).foregroundStyle(.secondary)
                        FixedFeeStats(project: project)
                    }
                    OptionalDecimalField(
                        title: "Hourly rate",
                        value: $project.rateOverride,
                        prompt: "Client default (\(Money.format(project.client?.defaultRate ?? 0)))"
                    )
                    Toggle("Billable", isOn: $project.isBillable)
                    Toggle("Favourite", isOn: $project.isFavourite)
                    Toggle("Archived", isOn: $project.isArchived)
                }

                Section {
                    ForEach(tasks) { task in
                        TaskRow(task: task, siblings: tasks.filter { $0.persistentModelID != task.persistentModelID && !$0.isArchived },
                                projectRate: project.rateOverride ?? project.client?.defaultRate ?? 0)
                    }
                } header: {
                    HStack {
                        Text("Tasks")
                        Spacer()
                        Menu {
                            Button("Add Default Tasks") {
                                TaskTemplates.addMissingDefaults(to: project, settings: settings, context: context)
                                try? context.save()
                            }
                            Button("Archive Tasks Not on the Default List") {
                                TaskTemplates.archiveNonDefaults(in: project, settings: settings)
                                try? context.save()
                            }
                            Divider()
                            Button("New Custom Task", action: addTask)
                        } label: {
                            Label("Tasks", systemImage: "plus")
                        } primaryAction: {
                            TaskTemplates.addMissingDefaults(to: project, settings: settings, context: context)
                            try? context.save()
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Click to add any missing default tasks; use the arrow for more")
                    }
                } footer: {
                    if missingDefaults > 0 {
                        Text("\(missingDefaults) default task\(missingDefaults == 1 ? " is" : "s are") missing from this project.")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Use ••• › Merge Into on an old task to move its time onto a default task.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") {
                    try? context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
    }

    private var settings: BusinessSettings { BusinessSettings.current(in: context) }

    private var missingDefaults: Int {
        let names = Set(project.tasks.filter { !$0.isArchived }.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() })
        return settings.defaultTasks.filter { !names.contains($0.name.trimmingCharacters(in: .whitespaces).lowercased()) }.count
    }

    private func addTask() {
        context.insert(TaskType(name: "New Task", project: project))
        try? context.save()
    }
}

private struct TaskRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var task: TaskType
    let siblings: [TaskType]
    let projectRate: Decimal
    @State private var mergeTarget: TaskType?

    var body: some View {
        HStack {
            TextField("Task name", text: $task.name)
                .labelsHidden()
                .foregroundStyle(task.isArchived ? .secondary : .primary)
            OptionalDecimalField(title: "Rate", value: $task.rateOverride, prompt: Money.format(projectRate))
                .labelsHidden()
                .frame(width: 110)
                .help("Task rate override; blank uses the project rate")
            Toggle("Billable", isOn: $task.isBillable)
                .toggleStyle(.checkbox)
            Menu {
                Button(task.isArchived ? "Unarchive" : "Archive") { task.isArchived.toggle() }
                Menu("Merge Into") {
                    ForEach(siblings) { other in
                        Button(other.name) { mergeTarget = other }
                    }
                }
                .disabled(siblings.isEmpty)
                Button("Delete", role: .destructive) {
                    context.delete(task)
                    try? context.save()
                }
                .disabled(!task.entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .confirmationDialog("Merge \"\(task.name)\" into \"\(mergeTarget?.name ?? "")\"?", isPresented: Binding(
                get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }
            )) {
                Button("Merge") {
                    if let mergeTarget { TaskTemplates.merge(task, into: mergeTarget, context: context) }
                }
            } message: {
                Text("\(task.entries.count) time entr\(task.entries.count == 1 ? "y moves" : "ies move") to \"\(mergeTarget?.name ?? "")\" and \"\(task.name)\" is deleted. Sent invoices aren't affected.")
            }
        }
    }
}

/// Hours used against a fixed fee, and the effective hourly rate it works out to.
private struct FixedFeeStats: View {
    let project: Project

    private var seconds: TimeInterval {
        project.tasks.flatMap(\.entries).reduce(0) { $0 + $1.liveDuration() }
    }

    var body: some View {
        let hours = DurationFormat.hours(seconds)
        LabeledContent("Tracked", value: HoursFormat.long(hours))
        if let fee = project.fixedFee, fee > 0, hours > 0 {
            LabeledContent("Effective rate", value: "\(Money.format(Money.round(fee / hours)))/h")
        }
    }
}
