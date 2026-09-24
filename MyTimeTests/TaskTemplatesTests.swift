import Foundation
import SwiftData
import Testing
@testable import MyTime

@MainActor
struct TaskTemplatesTests {
    let container: ModelContainer
    let context: ModelContext
    let settings: BusinessSettings
    let client: Client

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        settings = BusinessSettings.current(in: context)
        client = Client(name: "Acme", defaultRate: 150)
        context.insert(client)
    }

    @Test func newProjectsGetDefaultTasks() {
        let project = TaskTemplates.makeProject(client: client, settings: settings, context: context)
        #expect(project.tasks.count == DefaultTask.recommended.count)
        #expect(project.tasks.first { $0.name == "12. Admin" }?.isBillable == false)
        #expect(project.tasks.first { $0.name == "4. Engineering & implementation" }?.isBillable == true)
    }

    @Test func applyAddsMissingAndArchivesOthersKeepingTime() {
        let project = Project(name: "Internal", client: client)
        context.insert(project)
        let old = TaskType(name: "Team meeting", project: project)
        context.insert(old)
        let existing = TaskType(name: "2. meetings & workshops", project: project) // case-insensitive match
        existing.isArchived = true
        context.insert(existing)
        context.insert(TimeEntry(task: old, date: .now, durationSeconds: 2700))

        let outcome = TaskTemplates.applyToAllProjects(archiveOthers: true, settings: settings, context: context)
        #expect(outcome.added == DefaultTask.recommended.count) // 11 new + 1 unarchived
        #expect(outcome.archived == 1)
        #expect(old.isArchived && old.entries.count == 1)
        #expect(!existing.isArchived)
        #expect(project.tasks.count == DefaultTask.recommended.count + 1)
    }

    @Test func mergeMovesTimeAndDeletesSource() throws {
        let project = TaskTemplates.makeProject(client: client, settings: settings, context: context)
        let old = TaskType(name: "Team meeting", project: project)
        context.insert(old)
        let entry = TimeEntry(task: old, date: .now, durationSeconds: 2700)
        context.insert(entry)
        let target = try #require(project.tasks.first { $0.name.hasPrefix("2.") })

        TaskTemplates.merge(old, into: target, context: context)
        #expect(entry.task?.name == "2. Meetings & workshops")
        #expect(!project.tasks.contains { $0.name == "Team meeting" })
    }

    @Test func customListIsStored() {
        settings.defaultTasks = [DefaultTask(name: "Build"), DefaultTask(name: "Admin", isBillable: false)]
        #expect(settings.defaultTasks.map(\.name) == ["Build", "Admin"])
        let project = TaskTemplates.makeProject(client: client, settings: settings, context: context)
        #expect(project.tasks.count == 2)
    }
}
