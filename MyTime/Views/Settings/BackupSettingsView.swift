import SwiftUI

struct BackupSettingsView: View {
    @State private var backup = BackupService.shared
    @State private var restoreCandidate: URL?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: backup.isInICloud ? "icloud.fill" : "folder.fill")
                        .font(.title)
                        .foregroundStyle(backup.isInICloud ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backup.isInICloud ? "Backing up to iCloud Drive" : "Backing up to a local folder")
                            .font(.headline)
                        Text(statusLine).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await backup.backUpNow() }
                    } label: {
                        if backup.isWorking { ProgressView().controlSize(.small) } else { Text("Back Up Now") }
                    }
                    .disabled(backup.isWorking)
                }
                if let error = backup.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                }
            }

            Section("Settings") {
                Toggle("Back up automatically every day", isOn: $backup.automatic)
                Stepper("Keep the last \(backup.keepCount) daily backups", value: $backup.keepCount, in: 3...365)
                LabeledContent("Folder") {
                    HStack {
                        Text(displayPath(backup.folder)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…", action: chooseFolder)
                        Button("Show") { NSWorkspace.shared.open(ensureFolder()) }
                    }
                }
                if !backup.isInICloud, BackupService.iCloudDriveAvailable {
                    Button("Use iCloud Drive") { backup.folder = BackupFiles.defaultFolder }
                }
            }

            Section {
                if backup.backups.isEmpty {
                    Text("No backups yet.").foregroundStyle(.secondary)
                }
                ForEach(backup.backups.prefix(8), id: \.self) { url in
                    HStack {
                        Image(systemName: "doc.zipper").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(BackupFiles.created(url).formatted(date: .abbreviated, time: .shortened))
                            if url.lastPathComponent.contains("(") {
                                Text("Before restore").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Text(size(url)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Button("Restore…") { restoreCandidate = url }
                    }
                }
                Button("Restore from File…", action: chooseRestoreFile)
            } header: {
                Text("Backups")
            } footer: {
                Text("To move to a new Mac: install MyTime, open Settings → Backup, click Restore from File… and pick a backup from iCloud Drive › MyTime Backups.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { backup.refresh() }
        .confirmationDialog("Restore this backup?", isPresented: Binding(
            get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } }
        )) {
            Button("Restore and Relaunch", role: .destructive) {
                if let url = restoreCandidate { Task { await backup.restore(from: url) } }
            }
        } message: {
            Text("MyTime will replace all its data with the backup from \(restoreCandidate.map { BackupFiles.created($0).formatted(date: .abbreviated, time: .shortened) } ?? "") and relaunch. Your current data is backed up first, labelled \"Before restore\".")
        }
    }

    private var statusLine: String {
        guard let last = backup.lastBackup else { return "No backup yet" }
        return "Last backup \(last.formatted(.relative(presentation: .named)))"
    }

    private func displayPath(_ url: URL) -> String {
        if let drive = BackupFiles.iCloudDrive, url.path.hasPrefix(drive.path) {
            return "iCloud Drive" + url.path.dropFirst(drive.path.count).replacingOccurrences(of: "/", with: " › ")
        }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func ensureFolder() -> URL {
        try? FileManager.default.createDirectory(at: backup.folder, withIntermediateDirectories: true)
        return backup.folder
    }

    private func size(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = backup.folder
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { backup.folder = url }
    }

    private func chooseRestoreFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = ensureFolder()
        panel.message = "Choose a MyTime backup (.zip)"
        if panel.runModal() == .OK, let url = panel.url { restoreCandidate = url }
    }
}
