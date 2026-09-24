import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case timesheet = "Timesheet"
    case projects = "Projects"
    case clients = "Clients"
    case invoices = "Invoices"
    var id: Self { self }
}

struct MainView: View {
    let timer: TimerService
    @AppStorage("mainSection") private var section: MainSection = .timesheet

    var body: some View {
        Group {
            switch section {
            case .timesheet:
                TimesheetView(timer: timer)
            case .projects:
                ProjectsView()
            case .clients:
                ClientsView()
            case .invoices:
                InvoicesView()
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $section) {
                    ForEach(MainSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .onAppear { AppWindows.mainWindowDidAppear() }
        .onDisappear { AppWindows.mainWindowDidDisappear() }
    }
}
