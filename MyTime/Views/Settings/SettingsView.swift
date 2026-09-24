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
            Section("Keyboard shortcuts") {
                KeyboardShortcuts.Recorder("Show timer", name: .showTimer)
                KeyboardShortcuts.Recorder("Start / stop last timer", name: .toggleTimer)
                Text("These work from any app.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
