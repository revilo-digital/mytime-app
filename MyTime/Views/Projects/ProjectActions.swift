import SwiftData
import SwiftUI

extension Project {
    var allEntries: [TimeEntry] { tasks.flatMap(\.entries) }

    /// Projects with tracked time can't be deleted (it would orphan the time) — archive instead.
    var canDelete: Bool { allEntries.isEmpty }

    var trackedSeconds: TimeInterval { BillingSummary.totalSeconds(allEntries) }

    /// Value of all tracked billable time at the resolved rates — used as "spent" against a fixed fee.
    var spentValue: Decimal {
        allEntries.filter { $0.isBillable && RateResolver.isBillable($0.task) }
            .reduce(0) { $0 + BillingSummary.value(of: $1) }
    }
}

/// Edit… split button with favourite / archive / delete, shared by the client and projects views.
struct ProjectActionsMenu: View {
    @Environment(\.modelContext) private var context
    @Bindable var project: Project
    var onEdit: () -> Void
    var title = "Edit…"

    @State private var confirmDelete = false

    var body: some View {
        Menu {
            ProjectMenuItems(project: project, onEdit: onEdit, onDelete: { confirmDelete = true })
        } label: {
            Text(title)
        } primaryAction: {
            onEdit()
        }
        .menuStyle(.button)
        .fixedSize()
        .confirmationDialog("Delete \(project.name)?", isPresented: $confirmDelete) {
            Button("Delete Project", role: .destructive) {
                context.delete(project)
                try? context.save()
            }
        } message: {
            Text("Its \(project.tasks.count) task\(project.tasks.count == 1 ? "" : "s") will be deleted too. This can't be undone.")
        }
    }
}

/// Menu / context-menu items for a project.
struct ProjectMenuItems: View {
    @Bindable var project: Project
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        Button("Edit…", systemImage: "pencil", action: onEdit)
        Button(project.isFavourite ? "Remove from Favourites" : "Add to Favourites",
               systemImage: project.isFavourite ? "star.slash" : "star") { project.isFavourite.toggle() }
        Button(project.isArchived ? "Unarchive" : "Archive",
               systemImage: project.isArchived ? "tray.and.arrow.up" : "archivebox") { project.isArchived.toggle() }
        Divider()
        if project.canDelete {
            Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
        } else {
            Button("Delete… (has tracked time — archive instead)", systemImage: "trash") {}
                .disabled(true)
        }
    }
}
