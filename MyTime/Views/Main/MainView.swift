import SwiftData
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case timesheet = "Timesheet"
    case review = "Review"
    case projects = "Projects"
    case clients = "Clients"
    case invoices = "Invoices"
    var id: Self { self }
}

struct MainView: View {
    let timer: TimerService
    @AppStorage("mainSection") private var section: MainSection = .timesheet
    @Query private var beats: [ActivityBeat]
    @Query private var notes: [ActivityNote]
    @Query private var projects: [Project]
    // Read so a change in Settings redraws the suggestions.
    @AppStorage(ActivitySettings.roundingKey) private var rounding = ActivitySettings.defaultRoundingMinutes
    @AppStorage(ActivitySettings.minimumKey) private var minimum = ActivitySettings.defaultMinimumMinutes

    private var reviewCount: Int {
        ActivityTracker.suggestions(beats, notes: notes, projects: projects).count
    }

    var body: some View {
        Group {
            switch section {
            case .timesheet:
                TimesheetView(timer: timer)
            case .review:
                ReviewView(timer: timer)
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
                    ForEach(MainSection.allCases) { section in
                        let count = section == .review ? reviewCount : 0
                        Text(count > 0 ? "\(section.rawValue) (\(count))" : section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .onAppear { AppWindows.mainWindowDidAppear() }
        .onDisappear { AppWindows.mainWindowDidDisappear() }
    }
}
