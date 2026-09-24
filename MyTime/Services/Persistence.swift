import Foundation
import SwiftData

enum Persistence {
    static let schema = Schema([
        Client.self, Project.self, TaskType.self, TimeEntry.self, Invoice.self, InvoiceLine.self,
        BusinessSettings.self,
    ])

    /// ~/Library/Application Support/MyTime — kept explicit so backups can find the store.
    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "MyTime", directoryHint: .isDirectory)
    }

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            BackupFiles.applyPendingRestore(in: supportDirectory)
            config = ModelConfiguration(schema: schema, url: supportDirectory.appending(path: "MyTime.store"))
        }
        return try ModelContainer(for: schema, configurations: config)
    }

    /// Gives a brand-new store something to track against.
    @MainActor
    static func seedIfEmpty(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<Client>())) ?? 0
        guard count == 0 else { return }
        let client = Client(name: "Internal")
        let project = Project(name: "General", client: client)
        project.isBillable = false
        let task = TaskType(name: "Admin", project: project)
        task.isBillable = false
        context.insert(client)
        context.insert(project)
        context.insert(task)
        try? context.save()
    }
}
