import Foundation
import SwiftData
import Testing
@testable import MyTime

@MainActor
struct ActivityTrackerTests {
    let container: ModelContainer
    let context: ModelContext
    let project: Project
    let development: TaskType
    let meetings: TaskType
    let inbox: URL
    /// 9am local on a fixed day, so day boundaries are predictable.
    let nine: Date

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        let client = Client(name: "Acme", defaultRate: 150)
        project = Project(name: "Website", client: client)
        project.folders = ["/Users/me/code/website"]
        development = TaskType(name: "Development", project: project)
        meetings = TaskType(name: "Meetings", project: project)
        context.insert(client)
        context.insert(project)
        context.insert(development)
        context.insert(meetings)
        inbox = FileManager.default.temporaryDirectory.appending(path: "activity-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        nine = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)).addingTimeInterval(9 * 3600)
    }

    private func write(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: inbox.appending(path: "inbox.jsonl"), atomically: false, encoding: .utf8)
    }

    private func line(_ minutes: Double, _ folder: String = "/Users/me/code/website", source: String = "claude") -> String {
        "{\"at\":\(nine.addingTimeInterval(minutes * 60).timeIntervalSince1970),\"folder\":\"\(folder)\",\"source\":\"\(source)\"}"
    }

    private func note(_ minutes: Double, _ text: String, estimate: Double? = nil, _ folder: String = "/Users/me/code/website") -> String {
        let at = nine.addingTimeInterval(minutes * 60).timeIntervalSince1970
        let estimatePart = estimate.map { ",\"minutes\":\($0)" } ?? ""
        return "{\"type\":\"note\",\"at\":\(at),\"folder\":\"\(folder)\",\"source\":\"claude\",\"note\":\"\(text)\"\(estimatePart)}"
    }

    private func notes() throws -> [ActivityNote] {
        try context.fetch(FetchDescriptor<ActivityNote>(sortBy: [SortDescriptor(\.at)]))
    }

    private func beats() throws -> [ActivityBeat] {
        try context.fetch(FetchDescriptor<ActivityBeat>(sortBy: [SortDescriptor(\.at)]))
    }

    @Test func foldersMatchByPathComponentAndMostSpecificWins() {
        let other = Project(name: "Docs", client: project.client!)
        other.folders = ["/Users/me/code/website/docs/"]
        context.insert(other)
        let projects = [project, other]
        #expect(other.folders == ["/Users/me/code/website/docs"])
        #expect(ActivityTracker.project(for: "/Users/me/code/website", in: projects) === project)
        #expect(ActivityTracker.project(for: "/Users/me/code/website/src", in: projects) === project)
        #expect(ActivityTracker.project(for: "/Users/me/code/website/docs/api", in: projects) === other)
        #expect(ActivityTracker.project(for: "/Users/me/code/website-old", in: projects) == nil)
        project.isArchived = true
        #expect(ActivityTracker.project(for: "/Users/me/code/website", in: projects) == nil)
    }

    @Test func blocksSplitOnLongPausesAndAtMidnight() {
        let times = [0, 5, 19, 40, 41].map { nine.addingTimeInterval($0 * 60) }
        let blocks = ActivityTracker.blocks(times)
        #expect(blocks.map(\.duration) == [19 * 60, 60])

        let midnight = Calendar.current.startOfDay(for: nine).addingTimeInterval(86_400)
        let across = ActivityTracker.blocks([midnight.addingTimeInterval(-300), midnight.addingTimeInterval(300)])
        #expect(across.count == 2)
    }

    @Test func ingestEmptiesInboxDedupesAndSkipsBadLines() throws {
        try write([line(0), line(0.5), line(2), "not json", line(2, source: "cursor"), line(3, "~/elsewhere")])
        let kept = ActivityTracker.ingest(from: inbox, context: context, running: [], now: nine.addingTimeInterval(3600))
        #expect(kept == 4)
        let all = try beats()
        #expect(all.filter { $0.source == "claude" && $0.folder == "/Users/me/code/website" }.count == 2)
        #expect(all.contains { $0.folder == NSString(string: "~/elsewhere").expandingTildeInPath })
        #expect(!FileManager.default.fileExists(atPath: inbox.appending(path: "inbox.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: inbox.appending(path: "reading.jsonl").path))

        // A beat within a minute of one already stored is the same beat.
        try write([line(2.5)])
        #expect(ActivityTracker.ingest(from: inbox, context: context, running: [], now: nine.addingTimeInterval(3600)) == 0)
    }

    @Test func ingestSkipsProjectsWithARunningTimer() throws {
        let timer = TimerService(context: context, defaults: .tests)
        let entry = timer.start(task: meetings, now: nine)
        try write([line(1), line(2, "/Users/me/code/other")])
        ActivityTracker.ingest(from: inbox, context: context, running: [entry], now: nine.addingTimeInterval(600))
        #expect(try beats().map(\.folder) == ["/Users/me/code/other"])
    }

    @Test func suggestionsGroupFoldersOfOneProjectAndAcceptAddsToTodaysEntry() throws {
        project.folders.append("/Users/me/code/website-api")
        project.activityTaskID = development.uuid
        try write([line(0), line(10), line(12, "/Users/me/code/website-api"), line(30, "/Users/me/code/unknown"), line(35, "/Users/me/code/unknown")])
        ActivityTracker.ingest(from: inbox, context: context, running: [], now: nine.addingTimeInterval(3600))

        let suggestions = ActivityTracker.suggestions(try beats(), projects: [project])
        #expect(suggestions.count == 2)
        let website = try #require(suggestions.first { $0.project === project })
        #expect(website.duration == 12 * 60)
        #expect(website.project?.activityTask === development)
        let unknown = try #require(suggestions.first { $0.project == nil })
        #expect(unknown.folder == "/Users/me/code/unknown")

        let existing = TimeEntry(task: development, date: nine, durationSeconds: 3600, note: "Kickoff")
        context.insert(existing)
        let entry = ActivityTracker.accept(website, task: development, remember: true, context: context)
        #expect(entry === existing)
        #expect(existing.durationSeconds == 3600 + 12 * 60)
        #expect(try beats().allSatisfy { $0.folder == "/Users/me/code/unknown" })

        // Accepting an unlinked folder links it to the chosen task's project.
        let added = ActivityTracker.accept(unknown, task: meetings, remember: true, context: context)
        #expect(added !== existing)
        #expect(added.durationSeconds == 5 * 60)
        #expect(project.folders.contains("/Users/me/code/unknown"))
        #expect(project.activityTaskID == meetings.uuid)
        #expect(try beats().isEmpty)
    }

    @Test func dismissDropsBeatsAndShortBlocksAreNotOffered() throws {
        try write([line(0), line(20), line(22)])
        ActivityTracker.ingest(from: inbox, context: context, running: [], now: nine.addingTimeInterval(3600))
        let suggestions = ActivityTracker.suggestions(try beats(), projects: [project])
        #expect(suggestions.count == 1)
        // The lone beat at 9:00 is a zero-length block, left out; 9:20–9:22 is offered.
        #expect(suggestions[0].blocks.count == 1)
        #expect(suggestions[0].roundedDuration == 120)
        ActivityTracker.dismiss(suggestions[0], context: context)
        #expect(try beats().isEmpty)
    }

    @Test func labelsAreTidiedAndCutToThreeWords() {
        #expect(ActivityTracker.label("  fixed the invoice PDF layout. ") == "Fixed the invoice")
        #expect(ActivityTracker.label("Review tab.") == "Review tab")
        #expect(ActivityTracker.label("iOS app") == "IOS app")
        #expect(ActivityTracker.label("   ") == "")
    }

    @Test func similarLabelsMergeIntoOne() {
        #expect(ActivityTracker.mergeLabels(["Activity tracking", "activity tracking!", "Invoice layout", "AI activity tracking"])
                == ["AI activity tracking", "Invoice layout"])
        #expect(ActivityTracker.mergeLabels(["Review tab", "Tab"]) == ["Review tab"])
        // Whole words only: "Tab" isn't inside "Tables".
        #expect(ActivityTracker.mergeLabels(["Tables", "Tab"]) == ["Tables", "Tab"])
        #expect(ActivityTracker.mergeNote("Kickoff, review tab", adding: "Review tab, Invoice layout") == "Kickoff, review tab, Invoice layout")
        #expect(ActivityTracker.mergeNote("", adding: "Invoice layout") == "Invoice layout")
    }

    @Test func labelsJoinTheDaysMeasuredTimeAndAcceptMergesIntoOneEntry() throws {
        project.activityTaskID = development.uuid
        try write([line(0), line(12), line(24), line(30), note(10, "Review tab", estimate: 90), note(20, "review tab"), note(25, "Invoice layout")])
        ActivityTracker.ingest(from: inbox, context: context, running: [], now: nine.addingTimeInterval(3600))
        #expect(try notes().count == 3)

        let suggestions = ActivityTracker.suggestions(try beats(), notes: try notes(), projects: [project])
        #expect(suggestions.count == 1)
        let s = suggestions[0]
        #expect(s.note == "Review tab, Invoice layout")
        // Measured time wins over the estimate.
        #expect(s.duration == 30 * 60)
        #expect(!s.isEstimate)

        let existing = TimeEntry(task: development, date: nine, durationSeconds: 600, note: "Review tab")
        context.insert(existing)
        let entry = ActivityTracker.accept(s, task: development, remember: false, context: context)
        #expect(entry === existing)
        #expect(entry.note == "Review tab, Invoice layout")
        #expect(entry.durationSeconds == 600 + 30 * 60)
        #expect(try notes().isEmpty && beats().isEmpty)
    }

    @Test func aLabelWithNoMeasuredTimeUsesItsEstimate() throws {
        try write([note(0, "Planning call", estimate: 30), note(5, "Scoping", estimate: 15)])
        ActivityTracker.ingest(from: inbox, context: context, running: [], now: nine.addingTimeInterval(3600))
        let s = try #require(ActivityTracker.suggestions([], notes: try notes(), projects: [project]).first)
        #expect(s.isEstimate)
        #expect(s.roundedDuration == 45 * 60)
        // Your edits win when you accept.
        let entry = ActivityTracker.accept(s, task: meetings, duration: 3600, note: "Planning", remember: false, context: context)
        #expect(entry.durationSeconds == 3600)
        #expect(entry.note == "Planning")
    }
}
