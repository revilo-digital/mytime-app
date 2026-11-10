import SwiftData
import SwiftUI

/// Whether meetings are suggested, from which calendars, which project a calendar belongs to, and series
/// you've ignored.
struct CalendarSettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(MeetingSettings.enabledKey) private var enabled = false
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var settings = MeetingSettings.current
    private let store = CalendarStore.shared

    private var activeProjects: [Project] {
        projects.filter { !$0.isArchived }
            .sorted { TaskPicker.title($0).localizedStandardCompare(TaskPicker.title($1)) == .orderedAscending }
    }

    private var accounts: [String] {
        var seen = Set<String>()
        return store.calendars.map(\.account).filter { seen.insert($0).inserted }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Suggest meetings from your calendars", isOn: Binding(
                    get: { enabled },
                    set: { setEnabled($0) }
                ))
                if enabled && store.isDenied {
                    HStack {
                        Label("MyTime isn't allowed to read your calendars.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Privacy Settings…") { CalendarStore.openPrivacySettings() }
                    }
                } else if enabled && !store.hasAccess {
                    Button("Allow Calendar Access…") { Task { await store.requestAccess() } }
                }
            } header: {
                Text("Meetings")
            } footer: {
                Text("Meetings on the calendars you tick show up in Review once they start, at their scheduled length, beside your AI activity. "
                     + "Meetings that are all-day, declined, cancelled or marked free are left out. Nothing is added "
                     + "to your timesheet unless you add it, and your calendars aren't changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if enabled && store.hasAccess {
                ForEach(accounts, id: \.self) { account in
                    Section(account.isEmpty ? "Other" : account) {
                        ForEach(store.calendars.filter { $0.account == account }) { calendar in
                            CalendarRow(calendar: calendar,
                                        included: settings.includes(calendar.id, byDefault: calendar.isIncludedByDefault),
                                        project: projects.first { $0.meetingLinks.contains(MeetingTracker.calendarLink(calendar.id)) },
                                        projects: activeProjects,
                                        setIncluded: { setIncluded(calendar, $0) },
                                        setProject: { setProject(calendar, $0) })
                        }
                    }
                }
                Section {
                    Button("Add a Calendar Account…") { CalendarStore.openInternetAccounts() }
                } footer: {
                    Text("MyTime reads the calendars on this Mac. To add Google, Outlook or Exchange calendars, add the "
                         + "account in System Settings › Internet Accounts (or in Calendar) and turn on Calendars for it. "
                         + "If a calendar is only used for one client, choose its project, and all its meetings are "
                         + "suggested there.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    if settings.ignoredSeries.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(settings.ignoredSeries.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending },
                            id: \.key) { id, title in
                        HStack {
                            Image(systemName: "eye.slash").foregroundStyle(.secondary)
                            Text(title.isEmpty ? "Untitled meeting" : title).lineLimit(1)
                            Spacer()
                            Button {
                                MeetingSettings.setIgnored(series: id, title: title, false)
                                reload()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Suggest this meeting again")
                        }
                    }
                } header: {
                    Text("Ignored recurring meetings")
                } footer: {
                    Text("Use Dismiss › Ignore This Series on a recurring meeting in Review to add one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private func reload() {
        settings = MeetingSettings.current
        store.refresh()
    }

    private func setEnabled(_ on: Bool) {
        MeetingSettings.setEnabled(on)
        enabled = on
        reload()
        if on && !store.hasAccess && !store.isDenied {
            Task {
                await store.requestAccess()
                reload()
            }
        }
    }

    private func setIncluded(_ calendar: CalendarStore.CalendarInfo, _ included: Bool) {
        let shown = store.calendars.map { (id: $0.id, included: settings.includes($0.id, byDefault: $0.isIncludedByDefault)) }
        MeetingSettings.setCalendar(calendar.id, included: included, shown: shown)
        reload()
    }

    private func setProject(_ calendar: CalendarStore.CalendarInfo, _ project: Project?) {
        MeetingTracker.setCalendar(calendar.id, project: project, among: projects)
        try? context.save()
    }
}

private struct CalendarRow: View {
    let calendar: CalendarStore.CalendarInfo
    let included: Bool
    let project: Project?
    let projects: [Project]
    let setIncluded: (Bool) -> Void
    let setProject: (Project?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { included }, set: { setIncluded($0) })) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(calendar.color.map(Color.init(nsColor:)) ?? .secondary)
                        .frame(width: 10, height: 10)
                    Text(calendar.title).lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            Picker("Project", selection: Binding(
                get: { project?.persistentModelID },
                set: { id in setProject(projects.first { $0.persistentModelID == id }) }
            )) {
                Text("Match each meeting").tag(PersistentIdentifier?.none)
                Divider()
                ForEach(projects) { project in
                    Text(TaskPicker.title(project)).tag(Optional(project.persistentModelID))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            .disabled(!included)
            .help("Suggest every meeting on this calendar on one project, or match each by who's invited")
        }
    }
}
