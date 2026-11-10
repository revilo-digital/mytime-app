import AppKit
import EventKit
import Foundation
import SwiftData

/// A calendar event as MyTime uses it, kept apart from EventKit so matching can be tested.
struct CalendarEvent: Identifiable, Hashable, Sendable {
    /// One occurrence: the event's calendar-independent id with its start. The same invite on two of your
    /// calendars has the same key, so it's suggested once.
    let key: String
    /// Shared by every occurrence of a recurring event; nil for a one-off.
    var seriesID: String?
    var title: String
    var start: Date
    var end: Date
    var calendarID: String
    var calendarTitle: String
    /// The account the calendar belongs to ("iCloud", "me@example.com").
    var accountTitle: String = ""
    /// Everyone else on the invite, as lowercased email addresses.
    var attendees: [String] = []
    /// Your own addresses on the invite, lowercased.
    var ownAddresses: [String] = []
    var isAllDay = false
    /// You declined it.
    var isDeclined = false
    /// Shown as free rather than busy, e.g. a reminder or an FYI.
    var isFree = false
    var isCancelled = false

    var id: String { key }
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// Your choices for calendar meetings: whether they're suggested, from which calendars, and series you never
/// want suggested.
struct MeetingSettings {
    static let enabledKey = "meetingsEnabled"
    static let calendarsKey = "meetingCalendars"
    static let sinceKey = "meetingsSince"
    static let ignoredSeriesKey = "meetingIgnoredSeries"

    var isEnabled = false
    /// Calendars whose meetings are suggested; nil until you choose, meaning every calendar but birthdays and
    /// subscribed ones (holidays, sports).
    var calendarIDs: Set<String>?
    /// Meetings before this aren't suggested, so turning meetings on doesn't bring up months of history.
    var since: Date = .distantPast
    /// Recurring series never suggested, by series id, with their titles for Settings.
    var ignoredSeries: [String: String] = [:]

    static var current: MeetingSettings { load(.standard) }

    static func load(_ defaults: UserDefaults) -> MeetingSettings {
        MeetingSettings(
            isEnabled: defaults.bool(forKey: enabledKey),
            calendarIDs: defaults.stringArray(forKey: calendarsKey).map(Set.init),
            since: (defaults.object(forKey: sinceKey) as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantPast,
            ignoredSeries: defaults.dictionary(forKey: ignoredSeriesKey) as? [String: String] ?? [:]
        )
    }

    func includes(_ calendarID: String, byDefault: Bool) -> Bool {
        calendarIDs?.contains(calendarID) ?? byDefault
    }

    /// Turning meetings on the first time starts them from the beginning of this week.
    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard, now: Date = .now) {
        defaults.set(enabled, forKey: enabledKey)
        if enabled, defaults.object(forKey: sinceKey) == nil {
            defaults.set(Week.start(of: now).timeIntervalSince1970, forKey: sinceKey)
        }
    }

    /// Includes or leaves out one calendar. The first choice fixes the others at what they showed.
    static func setCalendar(_ id: String, included: Bool, shown: [(id: String, included: Bool)],
                            defaults: UserDefaults = .standard) {
        var ids = defaults.stringArray(forKey: calendarsKey).map(Set.init)
            ?? Set(shown.filter(\.included).map(\.id))
        if included { ids.insert(id) } else { ids.remove(id) }
        defaults.set(ids.sorted(), forKey: calendarsKey)
    }

    static func setIgnored(series id: String, title: String, _ ignored: Bool, defaults: UserDefaults = .standard) {
        var series = defaults.dictionary(forKey: ignoredSeriesKey) as? [String: String] ?? [:]
        series[id] = ignored ? title : nil
        defaults.set(series, forKey: ignoredSeriesKey)
    }
}

/// Meetings from your calendars, offered in Review beside AI activity for you to add or dismiss.
///
/// Calendars are read through macOS (EventKit), so any account added to Calendar.app counts: iCloud, Google,
/// Exchange, CalDAV. A meeting is offered once it has started, at its scheduled length, unless it's all-day,
/// declined, cancelled or marked free. Nothing is stored about it until you add or dismiss it.
///
/// A meeting is matched to a project by, in order: its recurring series, the calendar it's on, or the people
/// invited ("people:acme.com", or the full address for someone on a public mail service). Tick "Always for…"
/// when adding a meeting to save the link; link a whole calendar in Settings › Calendars.
enum MeetingTracker {
    static let keepFor = ActivityTracker.keepFor

    /// Mail services shared by unrelated people, so a domain says nothing about who's on the invite.
    static let publicMailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com",
        "mac.com", "yahoo.com", "ymail.com", "aol.com", "protonmail.com", "proton.me", "pm.me", "fastmail.com",
        "hey.com", "gmx.com", "zoho.com", "xtra.co.nz", "yahoo.co.nz", "yahoo.co.uk", "hotmail.co.uk",
        "outlook.co.nz", "bigpond.com", "orcon.net.nz", "slingshot.co.nz", "vodafone.co.nz",
    ]

    // MARK: Links

    static func calendarLink(_ id: String) -> String { "calendar:" + id }
    static func seriesLink(_ id: String) -> String { "series:" + id }

    static func domain(_ address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...].lowercased().trimmingCharacters(in: .whitespaces)
        return domain.isEmpty ? nil : domain
    }

    /// The organisations on the invite as links, apart from your own: "people:acme.com", or
    /// "people:bob@gmail.com" for someone on a public mail service.
    static func peopleLinks(_ event: CalendarEvent) -> [String] {
        let own = Set((event.ownAddresses + [event.accountTitle]).compactMap(domain)).subtracting(publicMailDomains)
        let ownAddresses = Set(event.ownAddresses.map { $0.lowercased() })
        var seen = Set<String>()
        return event.attendees.compactMap { raw -> String? in
            let address = raw.lowercased().trimmingCharacters(in: .whitespaces)
            guard !ownAddresses.contains(address), let domain = domain(address), !own.contains(domain) else { return nil }
            return "people:" + (publicMailDomains.contains(domain) ? address : domain)
        }
        .filter { seen.insert($0).inserted }
    }

    /// "people at acme.com", "bob@gmail.com", "this series", "the Work calendar".
    static func describe(_ link: String, calendars: [String: String] = [:]) -> String {
        let (kind, value) = split(link)
        switch kind {
        case "people": return value.contains("@") ? value : "people at \(value)"
        case "series": return "this series"
        case "calendar": return calendars[value].map { "the \($0) calendar" } ?? "a calendar"
        default: return link
        }
    }

    static func split(_ link: String) -> (kind: String, value: String) {
        guard let colon = link.firstIndex(of: ":") else { return ("", link) }
        return (String(link[..<colon]), String(link[link.index(after: colon)...]))
    }

    /// How a meeting was matched to its project.
    enum Match: Equatable {
        case series
        case calendar
        case people([String])
    }

    /// The project a meeting belongs to: the one linked to its series, else its calendar, else the one linked
    /// to most of the people invited (nil on a tie).
    static func project(for event: CalendarEvent, in projects: [Project]) -> (project: Project, match: Match)? {
        let active = projects.filter { !$0.isArchived }
        if let series = event.seriesID, let project = active.first(where: { $0.meetingLinks.contains(seriesLink(series)) }) {
            return (project, .series)
        }
        if let project = active.first(where: { $0.meetingLinks.contains(calendarLink(event.calendarID)) }) {
            return (project, .calendar)
        }
        let people = Set(peopleLinks(event))
        guard !people.isEmpty else { return nil }
        let scored = active.map { project in (project, project.meetingLinks.filter(people.contains)) }
            .filter { !$0.1.isEmpty }
        guard let best = scored.map(\.1.count).max() else { return nil }
        let winners = scored.filter { $0.1.count == best }
        return winners.count == 1 ? (winners[0].0, .people(winners[0].1)) : nil
    }

    private static func tokens(_ text: String?) -> [String] {
        (text ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// For a meeting nothing links: the project it most likely belongs to. A client whose email is at the
    /// domain of someone invited counts most (their only active project, or the one named in the title); then
    /// a project, end client or client named in the title. Nil unless one project clearly wins.
    static func guessProject(for event: CalendarEvent, in projects: [Project]) -> Project? {
        let active = projects.filter { !$0.isArchived }
        let domains = Set(peopleLinks(event).map { split($0).value }.compactMap { $0.contains("@") ? nil : $0 })
        let title = Set(tokens(event.title))
        func named(_ project: Project) -> Int {
            func has(_ name: String?) -> Bool {
                let words = tokens(name)
                return !words.isEmpty && words.joined().count >= 3 && words.allSatisfy(title.contains)
            }
            if has(project.name) { return 3 }
            if has(project.endClient?.name) { return 2 }
            if has(project.client?.name) { return 1 }
            return 0
        }
        let atClient = active.filter { project in
            guard let domain = project.client.flatMap({ domain($0.email) }) else { return false }
            return domains.contains(domain)
        }
        if atClient.count == 1 { return atClient[0] }
        let pool = atClient.isEmpty ? active : atClient
        let scored = pool.map { ($0, named($0)) }.filter { $0.1 > 0 }
        guard let best = scored.map(\.1).max() else { return nil }
        let winners = scored.filter { $0.1 == best }
        return winners.count == 1 ? winners[0].0 : nil
    }

    // MARK: Suggestions

    struct Suggestion: Identifiable {
        let event: CalendarEvent
        let day: Date
        let project: Project?
        let match: Match?
        var guess: Project?
        var settings = ActivitySettings.exact
        /// Time this meeting shares with AI activity on the same day, which would otherwise count twice.
        var overlap: TimeInterval = 0

        var id: String { "meeting|" + event.key }
        var start: Date { event.start }
        var duration: TimeInterval { event.duration }
        var roundedDuration: TimeInterval { settings.rounded(duration) }
        /// The meeting's title, cut to a label for invoices.
        var note: String { ActivityTracker.label(event.title) }
        var peopleLinks: [String] { MeetingTracker.peopleLinks(event) }
        func isOngoing(at now: Date) -> Bool { now < event.end }

        /// What "Always for…" saves: the people invited, else the series. Empty when there's nothing to go on.
        var rememberLinks: [String] {
            let people = peopleLinks
            if !people.isEmpty { return people }
            return event.seriesID.map { [MeetingTracker.seriesLink($0)] } ?? []
        }
    }

    /// Meetings to offer, earliest first: started, on or after `since`, not handled, and not all-day,
    /// declined, cancelled, free or in an ignored series.
    static func suggestions(_ events: [CalendarEvent], handled: Set<String>, projects: [Project],
                            settings: MeetingSettings = .current, activity: ActivitySettings = .current,
                            now: Date = .now, calendar: Calendar = .current) -> [Suggestion] {
        var seen = Set<String>()
        return events
            .filter { event in
                !event.isAllDay && !event.isDeclined && !event.isFree && !event.isCancelled && event.duration > 0
                    && event.start <= now && event.start >= settings.since && now.timeIntervalSince(event.start) < keepFor
                    && !handled.contains(event.key)
                    && !(event.seriesID.map { settings.ignoredSeries[$0] != nil } ?? false)
            }
            .map { event -> Suggestion in
                let matched = project(for: event, in: projects)
                return Suggestion(event: event, day: calendar.startOfDay(for: event.start), project: matched?.project,
                                  match: matched?.match,
                                  guess: matched == nil ? guessProject(for: event, in: projects) : nil,
                                  settings: activity)
            }
            // The same invite on two calendars once, keeping the copy that's linked to a project.
            .sorted { ($0.project != nil ? 0 : 1, $0.event.start) < ($1.project != nil ? 0 : 1, $1.event.start) }
            .filter { seen.insert($0.event.key).inserted && seen.insert(sameMeeting($0.event)).inserted }
            .sorted { $0.event.start < $1.event.start }
    }

    /// Title and times: catches one meeting copied onto two calendars with different ids.
    private static func sameMeeting(_ event: CalendarEvent) -> String {
        "same|\(event.title.lowercased().trimmingCharacters(in: .whitespaces))|\(event.start.timeIntervalSince1970)|\(event.end.timeIntervalSince1970)"
    }

    /// How much of the meeting falls inside any of `blocks`.
    static func overlap(_ event: CalendarEvent, with blocks: [ActivityTracker.Block]) -> TimeInterval {
        ActivityTracker.union(blocks).reduce(0) { total, block in
            total + max(0, min(event.end, block.end).timeIntervalSince(max(event.start, block.start)))
        }
    }

    /// Suggestions with their overlap against the day's AI activity filled in.
    static func withOverlap(_ meetings: [Suggestion], activity: [ActivityTracker.Suggestion]) -> [Suggestion] {
        meetings.map { meeting in
            var meeting = meeting
            let blocks = activity.filter { $0.day == meeting.day }.flatMap(\.blocks)
            meeting.overlap = overlap(meeting.event, with: blocks)
            return meeting
        }
    }

    // MARK: Accept and dismiss

    /// Adds the meeting to `task` on its day and marks it handled. With `remember`, links the meeting's people
    /// (or series) to the task's project when it went elsewhere, and makes the task the project's meeting task.
    @MainActor @discardableResult
    static func accept(_ suggestion: Suggestion, task: TaskType, duration: TimeInterval? = nil, note: String? = nil,
                       remember: Bool, context: ModelContext) -> TimeEntry {
        let entry = ActivityTracker.addTime(to: task, day: suggestion.day, duration: duration ?? suggestion.roundedDuration,
                                            note: note ?? suggestion.note, context: context)
        if remember, let project = task.project {
            if suggestion.project?.persistentModelID != project.persistentModelID {
                let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
                link(suggestion.rememberLinks, to: project, among: projects)
            }
            project.meetingTaskID = task.uuid
        }
        markHandled(suggestion, context: context)
        return entry
    }

    @MainActor
    static func dismiss(_ suggestion: Suggestion, context: ModelContext) {
        markHandled(suggestion, context: context)
    }

    /// Never suggests this meeting's series again (Settings › Calendars to undo).
    @MainActor
    static func ignoreSeries(_ suggestion: Suggestion, context: ModelContext, defaults: UserDefaults = .standard) {
        guard let series = suggestion.event.seriesID else { return dismiss(suggestion, context: context) }
        MeetingSettings.setIgnored(series: series, title: suggestion.event.title, true, defaults: defaults)
        markHandled(suggestion, context: context)
    }

    /// Adds `links` to `project`, taking them off any other project so a meeting has one home.
    static func link(_ links: [String], to project: Project, among projects: [Project]) {
        guard !links.isEmpty else { return }
        for other in projects where other.persistentModelID != project.persistentModelID {
            let kept = other.meetingLinks.filter { !links.contains($0) }
            if kept.count != other.meetingLinks.count { other.meetingLinks = kept }
        }
        project.meetingLinks += links
    }

    /// Links a whole calendar to `project`, or to none.
    static func setCalendar(_ calendarID: String, project: Project?, among projects: [Project]) {
        let link = calendarLink(calendarID)
        for other in projects where other.meetingLinks.contains(link) { other.meetingLinks.removeAll { $0 == link } }
        project?.meetingLinks.append(link)
    }

    @MainActor
    private static func markHandled(_ suggestion: Suggestion, context: ModelContext) {
        context.insert(HandledMeeting(key: suggestion.event.key, at: suggestion.event.start))
        prune(context: context)
        try? context.save()
    }

    @MainActor
    static func prune(context: ModelContext, now: Date = .now) {
        let cutoff = now.addingTimeInterval(-keepFor - 86_400)
        try? context.delete(model: HandledMeeting.self, where: #Predicate { $0.at < cutoff })
    }
}

// MARK: - EventKit

/// Your calendars and their recent meetings, read through macOS. Refreshes when a calendar changes and each
/// minute while MyTime runs.
@MainActor @Observable
final class CalendarStore {
    static let shared = CalendarStore()

    struct CalendarInfo: Identifiable, Hashable {
        let id: String
        let title: String
        let account: String
        let color: NSColor?
        /// Included until you choose: everything but birthdays and subscribed calendars.
        let isIncludedByDefault: Bool
    }

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    private(set) var status = EKEventStore.authorizationStatus(for: .event)
    private(set) var calendars: [CalendarInfo] = []
    /// Meetings from the included calendars, from `MeetingSettings.since` (at most `keepFor` back) to now.
    private(set) var events: [CalendarEvent] = []

    var hasAccess: Bool { status == .fullAccess }
    var isDenied: Bool { status == .denied || status == .restricted || status == .writeOnly }

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Asks macOS for calendar access, once; later it's changed in System Settings.
    func requestAccess() async {
        let store = store
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
        }
        status = EKEventStore.authorizationStatus(for: .event)
        if hasAccess { store.reset() }
        refresh()
    }

    func refresh(now: Date = .now) {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status != self.status { self.status = status }
        guard hasAccess else {
            clear()
            return
        }
        let settings = MeetingSettings.current
        let all = store.calendars(for: .event)
        let calendars = all.map { calendar in
            CalendarInfo(id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source?.title ?? "",
                         color: calendar.color,
                         isIncludedByDefault: calendar.type != .birthday && calendar.type != .subscription)
        }
        .sorted { a, b in
            let account = a.account.localizedStandardCompare(b.account)
            return account == .orderedSame ? a.title.localizedStandardCompare(b.title) == .orderedAscending
                : account == .orderedAscending
        }
        if calendars != self.calendars { self.calendars = calendars }
        let defaults = Dictionary(calendars.map { ($0.id, $0.isIncludedByDefault) }, uniquingKeysWith: { a, _ in a })
        let included = all.filter { settings.includes($0.calendarIdentifier, byDefault: defaults[$0.calendarIdentifier] ?? true) }
        let start = max(settings.since, now.addingTimeInterval(-MeetingTracker.keepFor))
        guard settings.isEnabled, !included.isEmpty, start < now else {
            if !events.isEmpty { events = [] }
            return
        }
        let predicate = store.predicateForEvents(withStart: start, end: now.addingTimeInterval(60), calendars: included)
        let fetched = store.events(matching: predicate).map(Self.event)
        if fetched != events { events = fetched }
    }

    /// Assigning only on change, so the minute's refresh doesn't redraw views for nothing.
    private func clear() {
        if !calendars.isEmpty { calendars = [] }
        if !events.isEmpty { events = [] }
    }

    private static func address(_ participant: EKParticipant) -> String? {
        let url = participant.url
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let address = (url as NSURL).resourceSpecifier ?? ""
        return address.removingPercentEncoding?.lowercased() ?? address.lowercased()
    }

    private static func event(_ event: EKEvent) -> CalendarEvent {
        let baseID = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? event.calendarItemIdentifier
        let occurrence = (event.occurrenceDate ?? event.startDate).timeIntervalSince1970
        var people = (event.attendees ?? []).filter { $0.participantType != .room && $0.participantType != .resource }
        if let organizer = event.organizer, !people.contains(where: { address($0) == address(organizer) }) {
            people.append(organizer)
        }
        let me = people.filter(\.isCurrentUser)
        return CalendarEvent(
            key: "\(baseID)|\(Int(occurrence))",
            seriesID: event.hasRecurrenceRules ? baseID : nil,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            calendarID: event.calendar.calendarIdentifier,
            calendarTitle: event.calendar.title,
            accountTitle: event.calendar.source?.title ?? "",
            attendees: people.filter { !$0.isCurrentUser }.compactMap(address),
            ownAddresses: me.compactMap(address),
            isAllDay: event.isAllDay,
            isDeclined: (event.attendees ?? []).first(where: \.isCurrentUser)?.participantStatus == .declined,
            isFree: event.availability == .free,
            isCancelled: event.status == .canceled
        )
    }

    /// Opens Privacy & Security › Calendars.
    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    /// Opens Internet Accounts, where Google, Exchange and other calendars are added to the Mac.
    static func openInternetAccounts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
    }
}
