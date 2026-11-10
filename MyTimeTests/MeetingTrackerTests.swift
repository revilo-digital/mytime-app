import Foundation
import SwiftData
import Testing
@testable import MyTime

@MainActor
struct MeetingTrackerTests {
    let container: ModelContainer
    let context: ModelContext
    let acme: Client
    let website: Project
    let development: TaskType
    let meetings: TaskType
    let other: Project
    /// 9am local on a fixed day.
    let nine: Date
    let defaults: UserDefaults

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        acme = Client(name: "Acme", defaultRate: 150)
        acme.email = "accounts@acme.com"
        website = Project(name: "Website", client: acme)
        development = TaskType(name: "Development", project: website)
        meetings = TaskType(name: "Meetings", project: website)
        let globex = Client(name: "Globex")
        other = Project(name: "Portal", client: globex)
        context.insert(acme)
        context.insert(globex)
        context.insert(website)
        context.insert(other)
        context.insert(development)
        context.insert(meetings)
        try context.save()
        nine = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)).addingTimeInterval(9 * 3600)
        defaults = UserDefaults(suiteName: "meetings-\(UUID().uuidString)")!
    }

    private func event(_ title: String = "Weekly sync", at minutes: Double = 0, length: Double = 30,
                       key: String? = nil, series: String? = nil, calendar: String = "work",
                       attendees: [String] = ["bob@acme.com"], me: [String] = ["me@example.com"]) -> CalendarEvent {
        let start = nine.addingTimeInterval(minutes * 60)
        return CalendarEvent(key: key ?? "\(title)|\(minutes)", seriesID: series, title: title, start: start,
                             end: start.addingTimeInterval(length * 60), calendarID: calendar, calendarTitle: "Work",
                             accountTitle: "me@example.com", attendees: attendees, ownAddresses: me)
    }

    private var settings: MeetingSettings { MeetingSettings(isEnabled: true) }
    private var later: Date { nine.addingTimeInterval(8 * 3600) }

    private func suggest(_ events: [CalendarEvent], handled: Set<String> = [], settings: MeetingSettings? = nil,
                         now: Date? = nil) -> [MeetingTracker.Suggestion] {
        MeetingTracker.suggestions(events, handled: handled, projects: [website, other], settings: settings ?? self.settings,
                                   activity: .exact, now: now ?? later)
    }

    @Test func peopleLinksUseDomainsButFullAddressesOnPublicMail() {
        let links = MeetingTracker.peopleLinks(event(attendees: ["Bob@Acme.com", "sue@acme.com", "jo@gmail.com", "me@example.com"]))
        #expect(links == ["people:acme.com", "people:jo@gmail.com"])
    }

    @Test func yourOwnOrganisationIsLeftOut() {
        // On a client's own workspace calendar, colleagues there aren't "the client".
        let links = MeetingTracker.peopleLinks(event(attendees: ["bob@acme.com", "kim@partner.co"], me: ["me@acme.com"]))
        #expect(links == ["people:partner.co"])
    }

    @Test func leavesOutAllDayDeclinedFreeCancelledAndNotStarted() {
        var allDay = event("A", at: 0); allDay.isAllDay = true
        var declined = event("B", at: 60); declined.isDeclined = true
        var free = event("C", at: 120); free.isFree = true
        var cancelled = event("D", at: 180); cancelled.isCancelled = true
        let future = event("E", at: 9 * 60)
        let ok = event("F", at: 240)
        #expect(suggest([allDay, declined, free, cancelled, future, ok]).map(\.event.title) == ["F"])
    }

    @Test func handledSinceAndIgnoredSeriesAreLeftOut() {
        let old = event("Old", at: -24 * 60)
        let handled = event("Done", at: 60)
        let ignored = event("Standup", at: 120, series: "s1")
        let ok = event("New", at: 180)
        var settings = self.settings
        settings.since = Calendar.current.startOfDay(for: nine)
        settings.ignoredSeries = ["s1": "Standup"]
        #expect(suggest([old, handled, ignored, ok], handled: [handled.key], settings: settings).map(\.event.title) == ["New"])
    }

    @Test func sameInviteOnTwoCalendarsIsSuggestedOnceKeepingTheLinkedCopy() {
        website.meetingLinks = [MeetingTracker.calendarLink("client")]
        let personal = event("Kickoff", key: "uid-1|1", calendar: "work", attendees: [])
        let onClient = event("Kickoff", key: "uid-1|1", calendar: "client", attendees: [])
        let copied = event("Kickoff", key: "other-id", calendar: "home", attendees: [])
        let result = suggest([personal, onClient, copied])
        #expect(result.count == 1)
        #expect(result.first?.event.calendarID == "client")
        #expect(result.first?.project === website)
    }

    @Test func seriesBeatsCalendarBeatsPeople() {
        website.meetingLinks = ["people:acme.com"]
        other.meetingLinks = [MeetingTracker.calendarLink("work")]
        #expect(MeetingTracker.project(for: event(), in: [website, other])?.project === other)
        website.meetingLinks.append(MeetingTracker.seriesLink("s1"))
        let match = MeetingTracker.project(for: event(series: "s1"), in: [website, other])
        #expect(match?.project === website)
        #expect(match?.match == .series)
    }

    @Test func peopleMatchNeedsOneClearProject() {
        website.meetingLinks = ["people:acme.com"]
        other.meetingLinks = ["people:globex.com"]
        let both = event(attendees: ["bob@acme.com", "al@globex.com"])
        #expect(MeetingTracker.project(for: both, in: [website, other]) == nil)
        let mostlyAcme = event(attendees: ["bob@acme.com", "jo@gmail.com", "al@globex.com"])
        website.meetingLinks.append("people:jo@gmail.com")
        #expect(MeetingTracker.project(for: mostlyAcme, in: [website, other])?.project === website)
    }

    @Test func guessesFromTheClientsEmailDomainOrAProjectNamedInTheTitle() {
        #expect(MeetingTracker.guessProject(for: event(attendees: ["bob@acme.com"]), in: [website, other]) === website)
        #expect(MeetingTracker.guessProject(for: event("Portal review", attendees: []), in: [website, other]) === other)
        #expect(MeetingTracker.guessProject(for: event("Lunch", attendees: []), in: [website, other]) == nil)
    }

    @Test func overlapWithActivityIsMeasured() {
        let meeting = event(at: 0, length: 60)
        let blocks = [ActivityTracker.Block(start: nine.addingTimeInterval(-600), end: nine.addingTimeInterval(900)),
                      ActivityTracker.Block(start: nine.addingTimeInterval(600), end: nine.addingTimeInterval(1200)),
                      ActivityTracker.Block(start: nine.addingTimeInterval(3000), end: nine.addingTimeInterval(5000))]
        #expect(MeetingTracker.overlap(meeting, with: blocks) == 1200 + 600)
    }

    @Test func acceptAddsTimeRemembersPeopleAndMarksHandled() throws {
        let suggestion = try #require(suggest([event("Design review", attendees: ["bob@acme.com"])]).first)
        #expect(suggestion.project == nil)
        #expect(suggestion.guess === website)
        #expect(website.suggestedMeetingTask === meetings)
        let entry = MeetingTracker.accept(suggestion, task: meetings, remember: true, context: context)
        #expect(entry.durationSeconds == 1800)
        #expect(entry.note == "Design review")
        #expect(website.meetingLinks == ["people:acme.com"])
        #expect(website.meetingTaskID == meetings.uuid)
        let handled = try context.fetch(FetchDescriptor<HandledMeeting>()).map(\.key)
        #expect(handled == [suggestion.event.key])
        #expect(suggest([suggestion.event], handled: Set(handled)).isEmpty)
    }

    @Test func rememberingOnAnotherProjectMovesTheLink() throws {
        other.meetingLinks = ["people:acme.com"]
        let portalTask = TaskType(name: "Meetings", project: website)
        context.insert(portalTask)
        let suggestion = try #require(suggest([event()]).first)
        #expect(suggestion.project === other)
        MeetingTracker.accept(suggestion, task: portalTask, remember: true, context: context)
        #expect(other.meetingLinks.isEmpty)
        #expect(website.meetingLinks == ["people:acme.com"])
    }

    @Test func acceptJoinsTheDaysEntryForTheTask() throws {
        let existing = TimeEntry(task: meetings, date: nine, durationSeconds: 600, note: "Planning")
        context.insert(existing)
        let suggestion = try #require(suggest([event("Standup call", length: 15)]).first)
        let entry = MeetingTracker.accept(suggestion, task: meetings, remember: false, context: context)
        #expect(entry === existing)
        #expect(entry.durationSeconds == 1500)
        #expect(entry.note == "Planning, Standup call")
    }

    @Test func ignoringASeriesSavesItAndDismissesThisOne() throws {
        let suggestion = try #require(suggest([event("Standup", series: "s9")]).first)
        MeetingTracker.ignoreSeries(suggestion, context: context, defaults: defaults)
        #expect(MeetingSettings.load(defaults).ignoredSeries == ["s9": "Standup"])
        #expect(try context.fetchCount(FetchDescriptor<HandledMeeting>()) == 1)
    }

    @Test func linkingACalendarMovesItBetweenProjects() {
        MeetingTracker.setCalendar("cal", project: website, among: [website, other])
        MeetingTracker.setCalendar("cal", project: other, among: [website, other])
        #expect(website.meetingLinks.isEmpty)
        #expect(other.meetingLinks == ["calendar:cal"])
        MeetingTracker.setCalendar("cal", project: nil, among: [website, other])
        #expect(other.meetingLinks.isEmpty)
    }

    @Test func calendarChoicesStartFromWhatWasShown() {
        let shown = [(id: "a", included: true), (id: "b", included: true), (id: "birthdays", included: false)]
        MeetingSettings.setCalendar("b", included: false, shown: shown, defaults: defaults)
        let settings = MeetingSettings.load(defaults)
        #expect(settings.includes("a", byDefault: false))
        #expect(!settings.includes("b", byDefault: true))
        #expect(!settings.includes("birthdays", byDefault: true))
    }

    @Test func turningOnStartsFromThisWeekOnce() {
        MeetingSettings.setEnabled(true, defaults: defaults, now: nine)
        let since = MeetingSettings.load(defaults).since
        #expect(since == Week.start(of: nine))
        MeetingSettings.setEnabled(false, defaults: defaults)
        MeetingSettings.setEnabled(true, defaults: defaults, now: nine.addingTimeInterval(30 * 86_400))
        #expect(MeetingSettings.load(defaults).since == since)
    }

    @Test func reviewListsLatestDayFirstAndInTimeOrderWithinADay() {
        let morning = suggest([event("Early", at: 0)])
        let tomorrow = suggest([event("Next", at: 24 * 60)], now: nine.addingTimeInterval(30 * 3600))
        let items = ReviewItem.merge(activity: [], meetings: morning + tomorrow + suggest([event("Late", at: 300)]))
        #expect(items.map(\.id) == ["meeting|Next|1440.0", "meeting|Early|0.0", "meeting|Late|300.0"])
    }
}
