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

        let suggestions = ActivityTracker.suggestions(try beats(), projects: [project], settings: .exact)
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
        let suggestions = ActivityTracker.suggestions(try beats(), projects: [project], settings: .exact)
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

        let suggestions = ActivityTracker.suggestions(try beats(), notes: try notes(), projects: [project], settings: .exact)
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
        let s = try #require(ActivityTracker.suggestions([], notes: try notes(), projects: [project], settings: .exact).first)
        #expect(s.isEstimate)
        #expect(s.roundedDuration == 45 * 60)
        // Your edits win when you accept.
        let entry = ActivityTracker.accept(s, task: meetings, duration: 3600, note: "Planning", remember: false, context: context)
        #expect(entry.durationSeconds == 3600)
        #expect(entry.note == "Planning")
    }

    @Test func commitsBecomeStretchesOfWorkMergedWithMeasuredTime() {
        let at = { (h: Double, m: Double) in Calendar.current.startOfDay(for: nine).addingTimeInterval(h * 3600 + m * 60) }
        let commits = ActivityTracker.commitBlocks([at(14, 45), at(15, 24), at(16, 0), at(18, 0)])
        #expect(commits == [
            .init(start: at(14, 15), end: at(16, 0), fromCommits: true),
            .init(start: at(17, 30), end: at(18, 0), fromCommits: true),
        ])
        // An early commit's lead-in stops at midnight.
        #expect(ActivityTracker.commitBlocks([at(0, 10)])[0].start == at(0, 0))

        let measured = ActivityTracker.Block(start: at(15, 50), end: at(16, 40))
        let merged = ActivityTracker.union(commits + [measured])
        #expect(merged == [
            .init(start: at(14, 15), end: at(16, 40), fromCommits: false),
            .init(start: at(17, 30), end: at(18, 0), fromCommits: true),
        ])
    }

    @Test func commitBeatsJoinTheDaysSuggestion() throws {
        let folder = "/Users/me/code/website"
        context.insert(ActivityBeat(at: nine.addingTimeInterval(3600), folder: folder, source: "git"))
        context.insert(ActivityBeat(at: nine, folder: folder, source: "claude"))
        context.insert(ActivityBeat(at: nine.addingTimeInterval(600), folder: folder, source: "claude"))
        let s = try #require(ActivityTracker.suggestions(try beats(), projects: [project], settings: .exact).first)
        // 9:00–9:10 measured, and 9:30–10:00 from the 10:00 commit.
        #expect(s.duration == 40 * 60)
        #expect(s.sources == ["claude", "git"])
        #expect(!s.isOngoing(at: nine.addingTimeInterval(3660)))
    }

    @Test func ingestCommitsKeepsNewOnesSkipsTrackedProjectsAndMovesTheMark() throws {
        let defaults = UserDefaults(suiteName: "nz.olly.MyTime.tests.commits")!
        defaults.removePersistentDomain(forName: "nz.olly.MyTime.tests.commits")
        let website = "/Users/me/code/website", other = "/Users/me/code/other"
        let marks = ActivityTracker.commitMarks(for: [website, other], defaults: defaults, now: nine)
        #expect(marks.allSatisfy { $0.after == Calendar.current.startOfDay(for: nine) })

        let timer = TimerService(context: context, defaults: .tests)
        let running = timer.start(task: development, now: nine)
        ActivityTracker.ingestCommits([
            (website, nine.addingTimeInterval(-60), [nine.addingTimeInterval(-120), nine.addingTimeInterval(60)]),
            (other, nine.addingTimeInterval(-60), [nine.addingTimeInterval(-120), nine.addingTimeInterval(60)]),
        ], context: context, running: [running], defaults: defaults)
        // Website's timer is running, so its commit is already counted; the older commit is before the mark.
        #expect(try beats().map(\.folder) == [other])
        let after = ActivityTracker.commitMarks(for: [website, other], defaults: defaults, now: nine)
        #expect(after.allSatisfy { $0.after == nine.addingTimeInterval(60) })
    }

    @Test func gitLogReadsOwnCommitTimes() throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "repo-\(UUID().uuidString)").path
        func git(_ args: String..., date: String? = nil) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo] + args
            var env = ProcessInfo.processInfo.environment
            if let date { env["GIT_COMMITTER_DATE"] = date; env["GIT_AUTHOR_DATE"] = date }
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git("init", "-q")
        try git("config", "user.email", "me@example.com")
        try git("config", "user.name", "Me")
        try git("config", "commit.gpgsign", "false")
        try git("commit", "-q", "--allow-empty", "-m", "one", date: "@1790000000 +0000")
        try git("commit", "-q", "--allow-empty", "-m", "two", date: "@1790003600 +0000")
        try git("-c", "user.email=someone@else.com", "commit", "-q", "--allow-empty", "-m", "theirs", date: "@1790005000 +0000")

        let times = GitLog.commitTimes(in: repo, after: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(times == [Date(timeIntervalSince1970: 1_790_003_600)])
        #expect(GitLog.commitTimes(in: "/nonexistent", after: .distantPast).isEmpty)
    }

    @Test func unlinkedSiblingFoldersGuessTheirProject() {
        let chatbot = Project(name: "Chatbot", client: project.client!)
        chatbot.folders = ["/Users/me/agency/helpdesk-chat-bot", "/Users/me/agency/helpdesk-chat-bot-infra"]
        context.insert(chatbot)
        let projects = [project, chatbot]
        #expect(ActivityTracker.guessProject(for: "/Users/me/agency/helpdesk", in: projects) === chatbot)
        #expect(ActivityTracker.guessProject(for: "/Users/me/elsewhere/helpdesk", in: projects) == nil)
        #expect(ActivityTracker.guessProject(for: "/Users/me/agency/unrelated", in: projects) == nil)
        // The folder's name in the project's name counts too.
        #expect(ActivityTracker.guessProject(for: "/Users/me/x/website-v2", in: projects) == nil)
        #expect(ActivityTracker.guessProject(for: "/Users/me/x/website", in: projects) === project)

        let s = ActivityTracker.Suggestion(day: nine, folder: "/Users/me/agency/helpdesk", project: nil, sources: [],
                                           blocks: [], beats: [], notes: [], guess: chatbot)
        #expect(s.guess === chatbot)
    }

    @Test func suggestedTaskIsTheChosenOneElseLastTrackedElseDevelopment() {
        #expect(project.suggestedTask === development)
        context.insert(TimeEntry(task: meetings, date: nine, durationSeconds: 60))
        #expect(project.suggestedTask === meetings)
        project.activityTaskID = development.uuid
        #expect(project.suggestedTask === development)
    }

    @Test func roundingAndMinimumFollowSettings() throws {
        let up5 = ActivitySettings(roundingMinutes: 5, minimumMinutes: 0)
        #expect(up5.rounded(0) == 0)
        #expect(up5.rounded(61) == 300)
        #expect(up5.rounded(302) == 300)
        #expect(up5.rounded(900) == 900)
        #expect(ActivitySettings(roundingMinutes: 6, minimumMinutes: 0).rounded(13 * 60) == 18 * 60)
        #expect(ActivitySettings.exact.rounded(89) == 60)

        let folder = "/Users/me/code/website"
        context.insert(ActivityBeat(at: nine, folder: folder, source: "claude"))
        context.insert(ActivityBeat(at: nine.addingTimeInterval(180), folder: folder, source: "claude"))
        let five = ActivitySettings(roundingMinutes: 5, minimumMinutes: 5)
        // Three minutes is under the five-minute minimum…
        #expect(ActivityTracker.suggestions(try beats(), projects: [project], settings: five).isEmpty)
        // …unless it has a label.
        context.insert(ActivityNote(at: nine, folder: folder, source: "claude", text: "Hotfix"))
        let s = try #require(ActivityTracker.suggestions(try beats(), notes: try notes(), projects: [project], settings: five).first)
        #expect(s.roundedDuration == 300)
    }

    @Test func ignoredFoldersAreDroppedAndNotCollected() throws {
        let defaults = UserDefaults(suiteName: "nz.olly.MyTime.tests.ignore")!
        defaults.removePersistentDomain(forName: "nz.olly.MyTime.tests.ignore")
        context.insert(ActivityBeat(at: nine, folder: "/Users/me/personal/blog", source: "claude"))
        context.insert(ActivityBeat(at: nine, folder: "/Users/me/code/website", source: "claude"))
        ActivityTracker.ignore("/Users/me/personal/", context: context, defaults: defaults)
        #expect(try beats().map(\.folder) == ["/Users/me/code/website"])

        let settings = ActivitySettings.load(defaults)
        #expect(settings.ignoredFolders == ["/Users/me/personal"])
        try write([line(0, "/Users/me/personal/notes"), line(1)])
        #expect(ActivityTracker.ingest(from: inbox, context: context, running: [], now: nine.addingTimeInterval(600), settings: settings) == 1)

        ActivitySettings.setIgnored("/Users/me/personal", false, defaults: defaults)
        #expect(ActivitySettings.load(defaults).ignoredFolders.isEmpty)
    }
}
