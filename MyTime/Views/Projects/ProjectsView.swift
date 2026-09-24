import SwiftData
import SwiftUI

/// All projects across clients, grouped by client, with budget burn for fixed-fee work.
struct ProjectsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name) private var clients: [Client]

    private enum Filter: String, CaseIterable, Identifiable {
        case active = "Active", archived = "Archived", all = "All"
        var id: Self { self }
    }

    @State private var filter = Filter.active
    @State private var clientFilter: PersistentIdentifier?
    @State private var search = ""
    @State private var editing: Project?

    private func matches(_ project: Project, _ filter: Filter) -> Bool {
        switch filter {
        case .active: !project.isArchived
        case .archived: project.isArchived
        case .all: true
        }
    }

    private var visible: [Project] {
        projects.filter { project in
            matches(project, filter)
                && (clientFilter == nil || project.client?.persistentModelID == clientFilter)
                && (search.isEmpty || project.name.localizedCaseInsensitiveContains(search)
                    || (project.client?.name.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    /// Visible projects grouped by client name, favourites first within each client.
    private var groups: [(client: String, projects: [Project])] {
        Dictionary(grouping: visible) { $0.client?.name ?? "No client" }
            .map { ($0.key, $0.value.sorted { ($0.isFavourite ? 0 : 1, $0.name) < ($1.isFavourite ? 0 : 1, $1.name) }) }
            .sorted { $0.client.localizedStandardCompare($1.client) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                stats
                table
            }
            .padding(24)
        }
        .sheet(item: $editing) { ProjectEditor(project: $0) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Projects").font(.title2.weight(.semibold))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by project or client", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
            .frame(width: 240)

            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { option in
                    Text("\(option.rawValue) (\(projects.filter { matches($0, option) }.count))").tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()

            Picker("Client", selection: $clientFilter) {
                Text("All clients").tag(PersistentIdentifier?.none)
                Divider()
                ForEach(clients) { Text($0.name).tag(Optional($0.persistentModelID)) }
            }
            .labelsHidden()
            .fixedSize()

            Menu {
                ForEach(clients) { client in
                    Button(client.name) { addProject(for: client) }
                }
            } label: {
                Label("New Project", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(clients.isEmpty)
        }
    }

    private var stats: some View {
        let active = projects.filter { !$0.isArchived }
        let entries = active.flatMap(\.allEntries)
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        let fixed = active.filter { $0.billingType == .fixedFee && ($0.fixedFee ?? 0) > 0 }
        let remaining = fixed.reduce(Decimal(0)) { $0 + (($1.fixedFee ?? 0) - $1.spentValue) }
        return HStack(spacing: 12) {
            StatCard(title: "Active projects", value: "\(active.count)", systemImage: "folder")
            StatCard(title: "This month", value: DurationFormat.short(BillingSummary.totalSeconds(entries.filter { $0.date >= monthStart })),
                     systemImage: "calendar")
            StatCard(title: "Uninvoiced", value: Money.format(BillingSummary.uninvoicedAmount(entries)),
                     systemImage: "dollarsign.circle", tint: .green)
            StatCard(title: "Fixed-fee budget left", value: fixed.isEmpty ? "—" : Money.format(remaining),
                     systemImage: "chart.bar", tint: remaining < 0 ? .red : .purple)
        }
    }

    // MARK: Table

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Project").frame(maxWidth: .infinity, alignment: .leading)
                Text("Budget").frame(width: Col.budget, alignment: .trailing)
                Text("Tracked").frame(width: Col.hours, alignment: .trailing)
                Text("Uninvoiced").frame(width: Col.uninvoiced, alignment: .trailing)
                Text("Remaining").frame(width: Col.remaining, alignment: .leading).padding(.leading, 8)
                Color.clear.frame(width: Col.actions, height: 1)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if groups.isEmpty {
                Divider()
                ContentUnavailableView("No projects", systemImage: "folder",
                                       description: Text(search.isEmpty ? "Create one with New Project." : "Nothing matches “\(search)”."))
                    .padding(.vertical, 24)
            }

            ForEach(groups, id: \.client) { group in
                Divider()
                HStack(spacing: 8) {
                    Avatar(name: group.client, size: 20, imageData: group.projects.first?.client?.logoData)
                    Text(group.client).font(.subheadline.weight(.semibold))
                    Text("\(group.projects.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.35))

                ForEach(group.projects) { project in
                    Divider().padding(.leading, 16)
                    ProjectTableRow(project: project) { editing = project }
                }
            }
        }
        .card(padding: 0, cornerRadius: 12)
    }

    private func addProject(for client: Client) {
        let project = TaskTemplates.makeProject(client: client, settings: BusinessSettings.current(in: context), context: context)
        editing = project
    }
}

private enum Col {
    static let budget: CGFloat = 100
    static let hours: CGFloat = 90
    static let uninvoiced: CGFloat = 100
    static let remaining: CGFloat = 230
    static let actions: CGFloat = 80
}

private struct ProjectTableRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var project: Project
    var onEdit: () -> Void

    @State private var hovering = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Button { project.isFavourite.toggle() } label: {
                    Image(systemName: project.isFavourite ? "star.fill" : "star")
                        .foregroundStyle(project.isFavourite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                Text(project.name).font(.body.weight(.medium)).lineLimit(1)
                if !project.code.isEmpty { Text(project.code).font(.caption).foregroundStyle(.secondary) }
                Tag(text: project.billingType == .hourly ? "Time & Materials" : "Fixed fee",
                    color: project.billingType == .hourly ? .blue : .purple)
                if !project.isBillable { Tag(text: "Non-billable") }
                if project.isArchived { Tag(text: "Archived", color: .orange) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(budgetText).frame(width: Col.budget, alignment: .trailing)
            Text(DurationFormat.short(project.trackedSeconds))
                .frame(width: Col.hours, alignment: .trailing)
            Text(project.billingType == .hourly ? Money.format(BillingSummary.uninvoicedAmount(project.allEntries)) : "—")
                .foregroundStyle(project.billingType == .hourly ? .primary : .secondary)
                .frame(width: Col.uninvoiced, alignment: .trailing)
            remaining.frame(width: Col.remaining, alignment: .leading).padding(.leading, 8)
            ProjectActionsMenu(project: project, onEdit: onEdit, title: "Actions")
                .frame(width: Col.actions, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear))
        .opacity(project.isArchived ? 0.6 : 1)
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

    private var budgetText: String {
        guard project.billingType == .fixedFee, let fee = project.fixedFee, fee > 0 else { return "—" }
        return Money.format(fee)
    }

    @ViewBuilder
    private var remaining: some View {
        if project.billingType == .fixedFee, let fee = project.fixedFee, fee > 0 {
            let spent = project.spentValue
            let left = fee - spent
            let fraction = min(1, max(0, NSDecimalNumber(decimal: spent / fee).doubleValue))
            let over = left < 0
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .tint(over ? .red : fraction > 0.8 ? .orange : .purple)
                    .frame(width: 80)
                Text("\(Money.format(left)) (\(Int((NSDecimalNumber(decimal: left / fee).doubleValue * 100).rounded()))%)")
                    .foregroundStyle(over ? .red : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .help("\(Money.format(spent)) of time tracked at your rates against a \(Money.format(fee)) fee")
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}
