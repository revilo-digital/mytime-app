import SwiftUI

/// Rounding, the smallest suggestion shown, and folders that are never tracked.
struct ActivitySettingsView: View {
    @AppStorage(ActivitySettings.roundingKey) private var rounding = ActivitySettings.defaultRoundingMinutes
    @AppStorage(ActivitySettings.minimumKey) private var minimum = ActivitySettings.defaultMinimumMinutes
    @State private var ignored = ActivitySettings.current.ignoredFolders
    @Environment(\.modelContext) private var context

    var body: some View {
        Form {
            Section {
                Picker("Round suggested time", selection: $rounding) {
                    ForEach(ActivitySettings.roundingChoices, id: \.self) { minutes in
                        Text(minutes == 1 ? "To the nearest minute" : "Up to \(minutes) minutes").tag(minutes)
                    }
                }
                Picker("Hide suggestions under", selection: $minimum) {
                    ForEach(ActivitySettings.minimumChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Show everything" : "\(minutes) minutes").tag(minutes)
                    }
                }
            } header: {
                Text("Suggestions")
            } footer: {
                Text("Time from Claude Code and your commits is rounded before it's suggested. You can still edit it "
                     + "before adding. A suggestion with a label is always shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if ignored.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(ignored, id: \.self) { folder in
                    HStack {
                        Image(systemName: "eye.slash").foregroundStyle(.secondary)
                        Text(ActivityTracker.abbreviate(folder)).lineLimit(1).truncationMode(.middle).help(folder)
                        Spacer()
                        Button {
                            ActivitySettings.setIgnored(folder, false)
                            ignored = ActivitySettings.current.ignoredFolders
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Track this folder again")
                    }
                }
                Button("Add Folder…", action: addFolders)
            } header: {
                Text("Ignored folders")
            } footer: {
                Text("Nothing is tracked in these folders or inside them, for personal or unbilled work. "
                     + "Use Dismiss › Ignore on a suggestion to add one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { ignored = ActivitySettings.current.ignoredFolders }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ignore"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { ActivityTracker.ignore(url.path, context: context) }
        ignored = ActivitySettings.current.ignoredFolders
    }
}
