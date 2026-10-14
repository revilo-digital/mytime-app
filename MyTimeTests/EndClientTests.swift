import Foundation
import SwiftData
import Testing
@testable import MyTime

@MainActor
struct EndClientTests {
    let container: ModelContainer
    let context: ModelContext
    let client: Client

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        client = Client(name: "Acme", defaultRate: 150)
        context.insert(client)
    }

    private func endClient(_ name: String) -> EndClient {
        let endClient = EndClient(name: name, client: client)
        context.insert(endClient)
        return endClient
    }

    private func project(_ name: String, endClient: EndClient? = nil) -> Project {
        let project = Project(name: name, client: client)
        project.endClient = endClient
        context.insert(project)
        return project
    }

    @Test func namesIncludeTheEndClient() throws {
        let task = TaskType(name: "Admin", project: project("Spring Campaign", endClient: endClient("Globex")))
        context.insert(task)
        let project = try #require(task.project)
        #expect(task.path == "Acme / Globex / Spring Campaign / Admin")
        #expect(task.shortPath == "Globex / Spring Campaign / Admin")
        #expect(TaskPicker.title(project) == "Acme › Globex › Spring Campaign")
        #expect(project.qualifiedName == "Globex – Spring Campaign")
    }

    @Test func namesWithoutAnEndClientAreUnchanged() {
        let task = TaskType(name: "Admin", project: project("Retainer"))
        context.insert(task)
        #expect(task.path == "Acme / Retainer / Admin")
        #expect(task.shortPath == "Retainer / Admin")
        #expect(task.project?.qualifiedName == "Retainer")
    }

    @Test func groupsOwnProjectsFirstThenEndClientsAToZ() {
        let initech = endClient("Initech")
        let globex = endClient("Globex")
        let unused = endClient("Zest")
        let projects = [project("Store", endClient: initech), project("Retainer"),
                        project("Spring Campaign", endClient: globex), project("Loyalty App", endClient: globex)]
        let groups = EndClientGroup.group(projects, including: [unused])
        #expect(groups.map { $0.endClient?.name } == [nil, "Globex", "Initech", "Zest"])
        #expect(groups[1].projects.map(\.name) == ["Spring Campaign", "Loyalty App"])
        #expect(groups[3].projects.isEmpty)
    }

    @Test func removingAnEndClientKeepsItsProjects() throws {
        let globex = endClient("Globex")
        let deal = project("Spring Campaign", endClient: globex)
        try context.save()
        context.delete(globex)
        try context.save()
        #expect(deal.endClient == nil)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 1)
    }

    @Test func deletingAClientDeletesItsEndClients() throws {
        _ = project("Spring Campaign", endClient: endClient("Globex"))
        try context.save()
        context.delete(client)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<EndClient>()) == 0)
    }
}
