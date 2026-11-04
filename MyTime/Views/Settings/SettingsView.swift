import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Business", systemImage: "building.2") {
                BusinessSettingsView()
            }
            Tab("Invoicing", systemImage: "doc.text") {
                InvoiceSettingsView()
            }
            Tab("Tasks", systemImage: "checklist") {
                TaskSettingsView()
            }
            Tab("AI Activity", systemImage: "sparkles") {
                ActivitySettingsView()
            }
            Tab("Backup", systemImage: "externaldrive.badge.icloud") {
                BackupSettingsView()
            }
        }
        .frame(width: 600, height: 640)
        .onAppear { AppWindows.mainWindowDidAppear() }
    }
}

private struct GeneralSettings: View {
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @AppStorage(AwayMonitor.thresholdKey) private var awayMinutes = AwayMonitor.defaultThresholdMinutes

    private var isInstalled: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch MyTime at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.set(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if LoginItem.needsApproval {
                    Button("Approve in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                if !isInstalled {
                    Text("MyTime isn't running from /Applications, so launch at login may point at a build folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Away from the Mac") {
                Picker("Ask about time away after", selection: $awayMinutes) {
                    ForEach(AwayMonitor.thresholdChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Never" : "\(minutes) minutes").tag(minutes)
                    }
                }
                Text(awayMinutes == 0
                     ? "Timers keep running however long you're away."
                     : "With a timer running and no keyboard or mouse use for this long, MyTime asks when you're back "
                        + "whether to keep or remove that time. Sleeping or locking the Mac counts as away straight "
                        + "away. If you're still away at midnight, the timer stops at the moment you left.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keyboard shortcuts") {
                KeyboardShortcuts.Recorder("Show timer", name: .showTimer)
                KeyboardShortcuts.Recorder("Start / stop last timer", name: .toggleTimer)
                Text("These work from any app.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
