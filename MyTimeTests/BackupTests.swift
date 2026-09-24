import Foundation
import SwiftData
import Testing
@testable import MyTime

@MainActor
struct BackupTests {
    private func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MyTimeTests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func container(at support: URL) throws -> ModelContainer {
        let config = ModelConfiguration(schema: Persistence.schema, url: support.appending(path: BackupFiles.storeName))
        return try ModelContainer(for: Persistence.schema, configurations: config)
    }

    @Test func backupRestoreRoundTrip() throws {
        let original = try tempDir("original")
        let backups = try tempDir("backups")
        let fresh = try tempDir("fresh")

        // A live store with unsaved-to-checkpoint WAL data.
        do {
            let source = try container(at: original)
            let client = Client(name: "Acme", defaultRate: 150)
            source.mainContext.insert(client)
            let project = Project(name: "Internal", client: client)
            source.mainContext.insert(project)
            let task = TaskType(name: "Team meeting", project: project)
            source.mainContext.insert(task)
            source.mainContext.insert(TimeEntry(task: task, date: .now, durationSeconds: 45 * 60))
            try source.mainContext.save()

            let zip = try BackupFiles.makeBackup(from: original, into: backups, label: nil)
            #expect(BackupFiles.list(in: backups).map(\.lastPathComponent) == [zip.lastPathComponent])

            // A fresh install has its own (seeded) store, which the restore replaces.
            let other = try container(at: fresh)
            other.mainContext.insert(Client(name: "Seeded"))
            try other.mainContext.save()

            try BackupFiles.stageRestore(from: zip, supportDirectory: fresh)
        }

        BackupFiles.applyPendingRestore(in: fresh)
        let restored = try container(at: fresh)
        let clients = try restored.mainContext.fetch(FetchDescriptor<Client>())
        #expect(clients.map(\.name) == ["Acme"])
        let entries = try restored.mainContext.fetch(FetchDescriptor<TimeEntry>())
        #expect(entries.count == 1, "entries: \(entries.map(\.durationSeconds))")
        #expect(entries.first?.durationSeconds == 2700.0)
        #expect(entries.first?.task?.project?.client?.name == "Acme")
        #expect(!FileManager.default.fileExists(atPath: fresh.appending(path: BackupFiles.pendingRestoreName).path))
    }

    @Test func rejectsNonBackupZip() throws {
        let dir = try tempDir("bogus")
        let zip = dir.appending(path: "nope.zip")
        try Data("not a zip".utf8).write(to: zip)
        #expect(throws: (any Error).self) { try BackupFiles.stageRestore(from: zip, supportDirectory: dir) }
    }

    @Test func prunesOnlyAutomaticBackups() throws {
        let dir = try tempDir("prune")
        let names = (1...4).map { BackupFiles.fileName(label: nil, at: Date(timeIntervalSince1970: TimeInterval($0) * 86400)) }
            + [BackupFiles.fileName(label: "Before restore", at: .distantPast)]
        for name in names { try Data().write(to: dir.appending(path: name)) }
        BackupFiles.prune(in: dir, keep: 2)
        let left = BackupFiles.list(in: dir).map(\.lastPathComponent)
        #expect(left.count == 3)
        #expect(left.contains { $0.contains("Before restore") })
    }
}
