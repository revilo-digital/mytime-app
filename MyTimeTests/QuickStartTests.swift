import Foundation
import SwiftData
import Testing
@testable import MyTime

@MainActor
struct QuickStartTests {
    let container: ModelContainer
    let context: ModelContext
    let website: Project
    let app: Project

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        let client = Client(name: "Acme", defaultRate: 150)
        website = Project(name: "Website", client: client)
        app = Project(name: "App", client: client)
        context.insert(client)
        context.insert(website)
        context.insert(app)
    }

    private func task(_ name: String, on project: Project) -> TaskType {
        let task = TaskType(name: name, project: project)
        context.insert(task)
        return task
    }

    /// Entries newest first, one per task given.
    private func entries(_ tasks: [TaskType]) -> [TimeEntry] {
        tasks.map { TimeEntry(task: $0, date: .now) }
    }

    @Test func starredTasksAndStarredProjectsAreFavouritesOnce() {
        let dev = task("Development", on: website)
        let meetings = task("Meetings", on: website)
        let design = task("Design", on: app)
        dev.isFavourite = true
        app.isFavourite = true
        design.isFavourite = true

        let favourites = QuickStart.favourites(tasks: [dev, meetings, design], entries: entries([design]))
        #expect(favourites.map(\.name) == ["Design", "Development"])
    }

    @Test func recentsAreTheLastThreeNotAlreadyFavourites() {
        let a = task("A", on: website), b = task("B", on: website), c = task("C", on: website)
        let d = task("D", on: website), e = task("E", on: website)
        let log = entries([a, b, a, c, d, e])

        #expect(QuickStart.recents(entries: log).map(\.name) == ["A", "B", "C"])
        #expect(QuickStart.recents(entries: log, excluding: [b]).map(\.name) == ["A", "C", "D"])
    }

    @Test func archivedTasksAreLeftOut() {
        let a = task("A", on: website), b = task("B", on: website)
        a.isFavourite = true
        a.isArchived = true
        #expect(QuickStart.favourites(tasks: [b], entries: []).isEmpty)
        #expect(QuickStart.recents(entries: entries([a, b])).map(\.name) == ["B"])
    }
}
