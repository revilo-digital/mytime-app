import Foundation
import SwiftData
import Testing
@testable import MyTime

@MainActor
struct RateResolverTests {
    let container: ModelContainer
    let client: Client
    let project: Project
    let task: TaskType

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        client = Client(name: "Acme", defaultRate: 120)
        project = Project(name: "Website", client: client)
        task = TaskType(name: "Development", project: project)
        container.mainContext.insert(client)
        container.mainContext.insert(project)
        container.mainContext.insert(task)
    }

    @Test func fallsBackToClientDefault() {
        #expect(RateResolver.rate(for: task) == 120)
    }

    @Test func projectOverridesClient() {
        project.rateOverride = 150
        #expect(RateResolver.rate(for: task) == 150)
    }

    @Test func taskOverridesProject() {
        project.rateOverride = 150
        task.rateOverride = Decimal(string: "175.50")!
        #expect(RateResolver.rate(for: task) == Decimal(string: "175.50")!)
    }

    @Test func billableNeedsProjectAndTask() {
        #expect(RateResolver.isBillable(task))
        project.isBillable = false
        #expect(!RateResolver.isBillable(task))
    }

    @Test func moneyRoundsHalfUpToCents() {
        #expect(Money.round(Decimal(string: "10.005")!) == Decimal(string: "10.01")!)
        #expect(Money.round(Decimal(string: "10.004")!) == Decimal(string: "10.00")!)
    }

    @Test func decimalFieldParsing() {
        #expect(OptionalDecimalField.parse("$1,050.50") == Decimal(string: "1050.50"))
        #expect(OptionalDecimalField.parse("  ") == nil)
    }
}
