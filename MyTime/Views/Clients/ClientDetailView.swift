import SwiftData
import SwiftUI

struct ClientDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var client: Client
    var onDelete: () -> Void

    @Query private var invoices: [Invoice]
    @State private var editingProject: Project?
    @State private var confirmDelete = false
    @State private var showArchivedProjects = false

    private var allEntries: [TimeEntry] { client.projects.flatMap(\.tasks).flatMap(\.entries) }
    private var hasTime: Bool { !allEntries.isEmpty }

    private var projects: [Project] {
        client.projects
            .filter { showArchivedProjects || !$0.isArchived }
            .sorted { ($0.isFavourite ? 0 : 1, $0.isArchived ? 1 : 0, $0.name) < ($1.isFavourite ? 0 : 1, $1.isArchived ? 1 : 0, $1.name) }
    }

    private var clientInvoices: [Invoice] {
        invoices.filter { $0.client?.persistentModelID == client.persistentModelID }
    }

    private var monthSeconds: TimeInterval {
        let start = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        return BillingSummary.totalSeconds(allEntries.filter { $0.date >= start })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                stats
                projectsSection
                detailsSection
                dangerZone
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(client.name)
        .sheet(item: $editingProject) { project in
            ProjectEditor(project: project)
        }
        .confirmationDialog("Delete \(client.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                context.delete(client)
                try? context.save()
                onDelete()
            }
        } message: {
            Text("This also deletes its projects and tasks.")
        }
        .onDisappear { try? context.save() }
    }

    // MARK: Sections

    private var hero: some View {
        HStack(spacing: 16) {
            LogoPicker(client: client)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Client name", text: $client.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .semibold))
                HStack(spacing: 8) {
                    Text("Default rate \(Money.format(client.defaultRate))/h")
                    if client.isArchived { Tag(text: "Archived", color: .orange) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var stats: some View {
        let outstanding = clientInvoices.filter { $0.status == .sent }.reduce(Decimal(0)) { $0 + $1.total }
        return HStack(spacing: 12) {
            StatCard(title: "Uninvoiced", value: Money.format(BillingSummary.uninvoicedAmount(allEntries.filter { $0.billingState == .unbilled })),
                     systemImage: "dollarsign.circle", tint: .green)
            StatCard(title: "Outstanding", value: Money.format(outstanding), systemImage: "clock.badge.exclamationmark",
                     tint: outstanding > 0 ? .orange : nil)
            StatCard(title: "This month", value: DurationFormat.short(monthSeconds), systemImage: "calendar")
            StatCard(title: "Invoices", value: "\(clientInvoices.count)", systemImage: "doc.text")
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Projects") {
                HStack(spacing: 12) {
                    if client.projects.contains(where: \.isArchived) {
                        Toggle("Show archived", isOn: $showArchivedProjects).toggleStyle(.checkbox).font(.caption)
                    }
                    Button(action: addProject) { Label("New Project", systemImage: "plus") }
                        .buttonStyle(.bordered)
                }
            }
            if projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus").font(.title).foregroundStyle(.secondary)
                    Text("No projects yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .card(padding: 28)
            }
            ForEach(projects) { project in
                ProjectCard(project: project) { editingProject = project }
            }
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Billing details")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                DetailField(label: "Billing name") { TextField("Shown on invoices", text: $client.billingName) }
                DetailField(label: "Email") { TextField("Invoices are emailed here", text: $client.email) }
                DetailField(label: "Address") {
                    TextField("Street, city, postcode", text: $client.address, axis: .vertical).lineLimit(2...5)
                }
                DetailField(label: "Logo") {
                    HStack(spacing: 10) {
                        Avatar(name: client.name, size: 32, imageData: client.logoData)
                        Button(client.logoData == nil ? "Choose…" : "Change…") { LogoPicker.choose(for: client) }
                        if client.logoData != nil {
                            Button("Remove") { client.logoData = nil }
                        }
                        Text("or drop an image on the circle above").font(.caption).foregroundStyle(.secondary)
                    }
                }
                DetailField(label: "Default rate") {
                    HStack {
                        DecimalField(title: "Rate", value: $client.defaultRate).labelsHidden().frame(width: 120)
                        Text("per hour").foregroundStyle(.secondary)
                    }
                }
            }
            .card(padding: 20)
        }
    }

    private var dangerZone: some View {
        HStack(spacing: 12) {
            Toggle("Archived", isOn: $client.isArchived)
                .toggleStyle(.switch)
                .help("Archived clients are hidden from timers and lists")
            Text("Hide from timers and lists").foregroundStyle(.secondary).font(.callout)
            Spacer()
            Button("Delete Client…", role: .destructive) { confirmDelete = true }
                .disabled(hasTime)
                .help(hasTime ? "Clients with tracked time can't be deleted — archive them instead." : "")
        }
        .card(padding: 16)
    }

    private func addProject() {
        let project = TaskTemplates.makeProject(client: client, settings: BusinessSettings.current(in: context), context: context)
        editingProject = project
    }
}

private struct ProjectCard: View {
    @Environment(\.modelContext) private var context
    @Bindable var project: Project
    var onEdit: () -> Void
    @State private var hovering = false
    @State private var confirmDelete = false

    private var activeTasks: [TaskType] {
        project.tasks.filter { !$0.isArchived }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var trackedSeconds: TimeInterval { project.trackedSeconds }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                project.isFavourite.toggle()
            } label: {
                Image(systemName: project.isFavourite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(project.isFavourite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(project.isFavourite ? "Remove from favourites" : "Add to favourites")

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(project.name).font(.title3.weight(.medium))
                    if !project.code.isEmpty { Text(project.code).font(.caption).foregroundStyle(.secondary) }
                    billingTag
                    if !project.isBillable { Tag(text: "Non-billable") }
                    if project.isArchived { Tag(text: "Archived", color: .orange) }
                }
                if !activeTasks.isEmpty {
                    FlowTags(items: activeTasks.map(\.name))
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(HoursFormat.long(DurationFormat.hours(trackedSeconds)))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text("tracked").font(.caption).foregroundStyle(.secondary)
            }

            ProjectActionsMenu(project: project, onEdit: onEdit)
                .controlSize(.large)
        }
        .card(padding: 16)
        .opacity(project.isArchived ? 0.6 : 1)
        .scaleEffect(hovering ? 1.004 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            ProjectMenuItems(project: project, onEdit: onEdit, onDelete: { confirmDelete = true })
        }
        .confirmationDialog("Delete \(project.name)?", isPresented: $confirmDelete) {
            Button("Delete Project", role: .destructive) {
                context.delete(project)
                try? context.save()
            }
        } message: {
            Text("Its tasks will be deleted too. This can't be undone.")
        }
    }

    @ViewBuilder
    private var billingTag: some View {
        switch project.billingType {
        case .hourly:
            Tag(text: project.rateOverride.map { "\(Money.format($0))/h" } ?? "Hourly", color: .blue)
        case .fixedFee:
            Tag(text: "Fixed fee" + (project.fixedFee.map { " \(Money.format($0))" } ?? ""), color: .purple)
        }
    }
}

/// Wrapping row of small grey chips.
private struct FlowTags: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
            }
        }
    }
}

/// Simple left-to-right wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
