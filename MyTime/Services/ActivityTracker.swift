import Foundation
import SwiftData

/// Your choices for AI activity: how suggested time is rounded, the smallest suggestion worth showing, and
/// folders whose activity is never tracked (personal or unbilled work).
struct ActivitySettings {
    static let roundingKey = "activityRoundingMinutes"
    static let minimumKey = "activityMinimumMinutes"
    static let ignoredKey = "activityIgnoredFolders"
    static let roundingChoices = [1, 5, 6, 10, 15, 30]
    static let minimumChoices = [0, 1, 5, 10, 15, 30]
    static let defaultRoundingMinutes = 5
    static let defaultMinimumMinutes = 5

    /// Suggested time is rounded up to a multiple of this; 1 rounds to the nearest minute.
    var roundingMinutes = defaultRoundingMinutes
    /// Suggestions with less time than this, and no label, aren't shown.
    var minimumMinutes = defaultMinimumMinutes
    var ignoredFolders: [String] = []

    /// Nearest minute, nothing hidden, nothing ignored.
    static let exact = ActivitySettings(roundingMinutes: 1, minimumMinutes: 0)

    static var current: ActivitySettings { load(.standard) }

    static func load(_ defaults: UserDefaults) -> ActivitySettings {
        ActivitySettings(
            roundingMinutes: defaults.object(forKey: roundingKey) as? Int ?? defaultRoundingMinutes,
            minimumMinutes: defaults.object(forKey: minimumKey) as? Int ?? defaultMinimumMinutes,
            ignoredFolders: defaults.stringArray(forKey: ignoredKey) ?? []
        )
    }

    func isIgnored(_ folder: String) -> Bool {
        ignoredFolders.contains { ActivityTracker.folder($0, contains: folder) }
    }

    func rounded(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds > 0 else { return 0 }
        guard roundingMinutes > 1 else { return (seconds / 60).rounded() * 60 }
        let step = TimeInterval(roundingMinutes * 60)
        // A second or two over a step isn't another step.
        return ((seconds - 5) / step).rounded(.up) * step
    }

    /// Adds `folder` to the ignored list, or takes it off.
    static func setIgnored(_ folder: String, _ ignored: Bool, defaults: UserDefaults = .standard) {
        let folder = ActivityTracker.normalize(folder)
        var list = (defaults.stringArray(forKey: ignoredKey) ?? []).filter { $0 != folder }
        if ignored { list.append(folder) }
        defaults.set(list.sorted(), forKey: ignoredKey)
    }
}

/// Time worked alongside AI coding tools (Claude Code, Cursor), offered on the timesheet for you to accept.
///
/// The tools' hooks (`scripts/activity-hook.sh`) append one JSON line per event to `Activity/inbox.jsonl` in
/// MyTime's support folder: `{"at": <unix seconds>, "folder": "<repo root>", "source": "claude"}`. MyTime reads
/// the inbox every minute, keeps at most one beat per folder and tool per minute, and leaves out beats for a
/// project whose timer is already running, so that time isn't counted twice. Beats up to `gap` apart form one
/// block of work.
///
/// A tool can also log a label for its work (`"type": "note", "note": "Invoice layout", "minutes": 40`). Labels
/// are cut to three words, since they become the entry's note on invoices, and a day's labels for a project are
/// merged into one suggestion with the measured time.
///
/// Your commits in linked repos count too: MyTime reads them with git every few minutes (`source: "git"`). Commits
/// up to `commitGap` apart are one stretch of work, which starts `commitLeadIn` before its first commit. Measured
/// and commit time are merged, so overlapping time counts once. Nothing reaches the timesheet until you accept it.
enum ActivityTracker {
    /// Longest pause that still counts as one block of work.
    static let gap: TimeInterval = 15 * 60
    /// Beats closer together than this, for the same folder and tool, are one beat.
    static let dedupeWindow: TimeInterval = 60
    /// Blocks shorter than this aren't offered.
    static let minimumBlock: TimeInterval = 60
    /// Beats nobody accepted or dismissed are dropped after this long.
    static let keepFor: TimeInterval = 30 * 86_400

    /// Commits further apart than this are separate stretches of work.
    static let commitGap: TimeInterval = 90 * 60
    /// Work counted before a stretch's first commit.
    static let commitLeadIn: TimeInterval = 30 * 60
    static let gitSource = "git"

    /// Longest label kept: notes appear on invoices.
    static let maxLabelWords = 3

    static var inboxDirectory: URL {
        Persistence.supportDirectory.appending(path: "Activity", directoryHint: .isDirectory)
    }

    // MARK: Folders

    /// Absolute, tilde-expanded, no trailing slash.
    static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).standardizingPath
    }

    /// Is `child` the folder `parent` or inside it? `/a/b` doesn't contain `/a/bc`.
    static func folder(_ parent: String, contains child: String) -> Bool {
        child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
    }

    /// The project whose folders most specifically contain `folder`.
    static func project(for folder: String, in projects: [Project]) -> Project? {
        var best: (project: Project, length: Int)?
        for project in projects where !project.isArchived {
            for parent in project.folders where Self.folder(parent, contains: folder) {
                if parent.count > (best?.length ?? -1) { best = (project, parent.count) }
            }
        }
        return best?.project
    }

    private static func tokens(_ text: String?) -> [String] {
        (text ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// For a folder no project links: the project it most likely belongs to. A sibling of a linked folder that
    /// shares the start of its name ("helpdesk" beside "helpdesk-chat-bot") counts most; then the folder's name appearing
    /// in the project's, end client's or client's name. Nil unless one project clearly wins.
    static func guessProject(for folder: String, in projects: [Project]) -> Project? {
        let name = tokens((folder as NSString).lastPathComponent)
        let parent = (folder as NSString).deletingLastPathComponent
        guard !name.isEmpty else { return nil }
        var scored: [(project: Project, score: Int)] = []
        for project in projects where !project.isArchived {
            var score = 0
            for linked in project.folders where (linked as NSString).deletingLastPathComponent == parent {
                let other = tokens((linked as NSString).lastPathComponent)
                let shared = zip(name, other).prefix { $0 == $1 }.count
                if shared > 0, shared == min(name.count, other.count) { score = max(score, 10 + shared) }
            }
            let names = Set(tokens(project.name) + tokens(project.endClient?.name) + tokens(project.client?.name))
            if name.allSatisfy(names.contains) { score = max(score, 5) }
            if score > 0 { scored.append((project, score)) }
        }
        let best = scored.map(\.score).max() ?? 0
        let winners = scored.filter { $0.score == best }
        return winners.count == 1 ? winners[0].project : nil
    }

    /// "~/Documents/projects/tracker"
    static func abbreviate(_ folder: String) -> String {
        (folder as NSString).abbreviatingWithTildeInPath
    }

    static func sourceName(_ source: String) -> String {
        switch source.lowercased() {
        case "claude": "Claude Code"
        case "cursor": "Cursor"
        case gitSource: "Git commits"
        default: source.capitalized
        }
    }

    // MARK: Inbox

    private struct Line: Decodable {
        let at: Double
        let folder: String
        let source: String?
        /// "beat" (default) or "note".
        let type: String?
        let note: String?
        let minutes: Double?
    }

    /// Moves new beats from the inbox into the store. Returns how many were kept.
    @MainActor @discardableResult
    static func ingest(from directory: URL = inboxDirectory, context: ModelContext, running: [TimeEntry], now: Date = .now,
                       settings: ActivitySettings = .current) -> Int {
        let fm = FileManager.default
        let inbox = directory.appending(path: "inbox.jsonl")
        let claimed = directory.appending(path: "reading.jsonl")
        var lines: [Line] = []
        // Claim the inbox with an atomic rename so hooks writing meanwhile start a fresh one. A claimed file
        // left behind by a crash is read first.
        for _ in 0..<2 {
            if !fm.fileExists(atPath: claimed.path) {
                guard (try? fm.moveItem(at: inbox, to: claimed)) != nil else { break }
            }
            if let data = try? Data(contentsOf: claimed) { lines += parse(data) }
            try? fm.removeItem(at: claimed)
        }

        prune(context: context, now: now)
        guard !lines.isEmpty else {
            try? context.save()
            return 0
        }

        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        let tracked = Set(running.filter(\.isRunning).compactMap { $0.task?.project?.persistentModelID })
        let earliest = Date(timeIntervalSince1970: lines.map(\.at).min() ?? 0).addingTimeInterval(-dedupeWindow)
        let recent = (try? context.fetch(FetchDescriptor<ActivityBeat>(predicate: #Predicate { $0.at >= earliest }))) ?? []
        var last: [String: Date] = [:]
        for beat in recent {
            let key = beat.source + "|" + beat.folder
            last[key] = max(last[key] ?? .distantPast, beat.at)
        }

        var kept = 0
        for line in lines.sorted(by: { $0.at < $1.at }) {
            let folder = normalize(line.folder)
            let source = (line.source ?? "claude").lowercased()
            let at = Date(timeIntervalSince1970: line.at)
            guard !folder.isEmpty, at <= now.addingTimeInterval(60), now.timeIntervalSince(at) < keepFor,
                  !settings.isIgnored(folder) else { continue }
            if line.type == "note" {
                let text = label(line.note ?? "")
                let estimate = max(0, min(line.minutes ?? 0, 24 * 60)) * 60
                guard !text.isEmpty || estimate > 0 else { continue }
                context.insert(ActivityNote(at: at, folder: folder, source: source, text: text, estimateSeconds: estimate))
                kept += 1
                continue
            }
            if let project = project(for: folder, in: projects), tracked.contains(project.persistentModelID) { continue }
            let key = source + "|" + folder
            if let previous = last[key], abs(at.timeIntervalSince(previous)) < dedupeWindow { continue }
            last[key] = at
            context.insert(ActivityBeat(at: at, folder: folder, source: source))
            kept += 1
        }
        try? context.save()
        return kept
    }

    private static func parse(_ data: Data) -> [Line] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Line.self, from: Data($0)) }
    }

    @MainActor
    private static func prune(context: ModelContext, now: Date) {
        let cutoff = now.addingTimeInterval(-keepFor)
        try? context.delete(model: ActivityBeat.self, where: #Predicate { $0.at < cutoff })
        try? context.delete(model: ActivityNote.self, where: #Predicate { $0.at < cutoff })
    }

    // MARK: Labels

    /// "  fixed the invoice PDF layout. " → "Fixed the invoice": tidied and cut to `maxLabelWords`.
    static func label(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(maxLabelWords)
        var result = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if let first = result.first, first.isLowercase { result = first.uppercased() + result.dropFirst() }
        return result
    }

    private static func words(_ label: String) -> [String] {
        label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func contains(_ outer: [String], _ inner: [String]) -> Bool {
        guard !inner.isEmpty, inner.count <= outer.count else { return false }
        return (0...(outer.count - inner.count)).contains { Array(outer[$0..<($0 + inner.count)]) == inner }
    }

    /// Labels in order with repeats dropped, ignoring case and punctuation. A label whose words appear within
    /// another ("Activity tracking" in "AI activity tracking") gives way to the longer one.
    static func mergeLabels(_ labels: [String]) -> [String] {
        var kept: [(label: String, words: [String])] = []
        for raw in labels {
            let label = label(raw)
            let w = words(label)
            guard !w.isEmpty, !kept.contains(where: { contains($0.words, w) }) else { continue }
            if let index = kept.firstIndex(where: { contains(w, $0.words) }) {
                kept[index] = (label, w)
                kept.removeAll { $0.label != label && contains(w, $0.words) }
            } else {
                kept.append((label, w))
            }
        }
        return kept.map(\.label)
    }

    /// An entry's note with `addition` appended, leaving out labels the note already has.
    static func mergeNote(_ note: String, adding addition: String) -> String {
        let existing = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteWords = words(existing)
        let new = addition.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !contains(noteWords, words($0)) }
        return ([existing].filter { !$0.isEmpty } + mergeLabels(new)).joined(separator: ", ")
    }

    // MARK: Suggestions

    struct Block: Equatable {
        var start: Date
        var end: Date
        /// Worked out from commits alone, with nothing measured in it.
        var fromCommits = false
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// One day's activity and labels for one project, or for one folder not yet linked to a project.
    struct Suggestion: Identifiable {
        let day: Date
        /// The folder the activity was in; the first one, when a project has several.
        let folder: String
        let project: Project?
        let sources: [String]
        let blocks: [Block]
        let beats: [ActivityBeat]
        let notes: [ActivityNote]
        /// For an unlinked folder, the project it probably belongs to.
        var guess: Project? = nil
        var settings = ActivitySettings.exact

        var id: String { "\(day.timeIntervalSince1970)|\(project.map { "\($0.persistentModelID.hashValue)" } ?? folder)" }
        var measured: TimeInterval { blocks.reduce(0) { $0 + $1.duration } }
        var estimate: TimeInterval { notes.reduce(0) { $0 + $1.estimateSeconds } }
        /// Measured time wins; the tools' estimates are used only when nothing was measured.
        var isEstimate: Bool { measured == 0 && estimate > 0 }
        var duration: TimeInterval { measured > 0 ? measured : estimate }
        /// Rounded as set in Settings, as it will be added to the timesheet.
        var roundedDuration: TimeInterval { settings.rounded(duration) }
        /// The day's labels, merged: the suggested note.
        var note: String { ActivityTracker.mergeLabels(notes.map(\.text)).joined(separator: ", ") }
        var start: Date { min(blocks.first?.start ?? .distantFuture, notes.first?.at ?? .distantFuture) }
        func isOngoing(at now: Date) -> Bool {
            guard let last = beats.last(where: { $0.source != ActivityTracker.gitSource })?.at else { return false }
            return now.timeIntervalSince(last) < ActivityTracker.gap
        }
    }

    /// Sorted times split into blocks wherever the pause is longer than `gap` or the day changes.
    static func blocks(_ times: [Date], gap: TimeInterval = gap, calendar: Calendar = .current) -> [Block] {
        var result: [Block] = []
        for time in times.sorted() {
            if var current = result.last, time.timeIntervalSince(current.end) <= gap,
               calendar.isDate(time, inSameDayAs: current.start) {
                current.end = time
                result[result.count - 1] = current
            } else {
                result.append(Block(start: time, end: time))
            }
        }
        return result
    }

    /// Commit times as stretches of work: commits up to `commitGap` apart join, and each stretch starts
    /// `commitLeadIn` before its first commit (not before midnight).
    static func commitBlocks(_ times: [Date], calendar: Calendar = .current) -> [Block] {
        blocks(times, gap: commitGap, calendar: calendar).map { block in
            let start = max(block.start.addingTimeInterval(-commitLeadIn), calendar.startOfDay(for: block.start))
            return Block(start: start, end: block.end, fromCommits: true)
        }
    }

    /// Overlapping or touching blocks merged into one.
    static func union(_ blocks: [Block]) -> [Block] {
        var result: [Block] = []
        for block in blocks.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, block.start <= last.end {
                last.end = max(last.end, block.end)
                last.fromCommits = last.fromCommits && block.fromCommits
                result[result.count - 1] = last
            } else {
                result.append(block)
            }
        }
        return result
    }

    /// Activity and labels grouped by day and project (or unlinked folder), earliest first. A day needs a block
    /// of at least `minimumBlock` or a label to be offered, and at least the minimum in `settings` unless it has
    /// a label. Ignored folders are left out.
    static func suggestions(_ beats: [ActivityBeat], notes: [ActivityNote] = [], projects: [Project],
                            settings: ActivitySettings = .current, calendar: Calendar = .current) -> [Suggestion] {
        let beats = beats.filter { !settings.isIgnored($0.folder) }
        let notes = notes.filter { !settings.isIgnored($0.folder) }
        struct Key: Hashable { let day: Date; let group: String }
        struct Group { var project: Project?; var beats: [ActivityBeat] = []; var notes: [ActivityNote] = [] }
        var groups: [Key: Group] = [:]
        func key(_ folder: String, _ at: Date) -> (Key, Project?) {
            let project = project(for: folder, in: projects)
            let group = project.map { "p\($0.persistentModelID.hashValue)" } ?? "f" + folder
            return (Key(day: calendar.startOfDay(for: at), group: group), project)
        }
        for beat in beats {
            let (k, project) = key(beat.folder, beat.at)
            groups[k, default: Group(project: project)].beats.append(beat)
        }
        for note in notes {
            let (k, project) = key(note.folder, note.at)
            groups[k, default: Group(project: project)].notes.append(note)
        }
        return groups.compactMap { key, group -> Suggestion? in
            let beats = group.beats.sorted { $0.at < $1.at }
            let notes = group.notes.sorted { $0.at < $1.at }
            let measured = blocks(beats.filter { $0.source != gitSource }.map(\.at), calendar: calendar)
                .filter { $0.duration >= minimumBlock }
            let commits = commitBlocks(beats.filter { $0.source == gitSource }.map(\.at), calendar: calendar)
            let blocks = union(measured + commits)
            guard !blocks.isEmpty || !notes.isEmpty,
                  let folder = beats.first?.folder ?? notes.first?.folder else { return nil }
            var seen = Set<String>()
            let suggestion = Suggestion(
                day: key.day, folder: folder, project: group.project,
                sources: (beats.map(\.source) + notes.map(\.source)).filter { seen.insert($0).inserted },
                blocks: blocks, beats: beats, notes: notes,
                guess: group.project == nil ? guessProject(for: folder, in: projects) : nil,
                settings: settings
            )
            guard !notes.isEmpty || suggestion.duration >= TimeInterval(settings.minimumMinutes * 60) else { return nil }
            return suggestion
        }
        .sorted { ($0.day, $0.start) < ($1.day, $1.start) }
    }

    // MARK: Commits

    /// UserDefaults key: per folder, the latest commit time already read.
    static let commitMarksKey = "activityCommitMarks"

    /// Folders to read commits from: every linked folder of an active project.
    @MainActor
    static func commitFolders(context: ModelContext, settings: ActivitySettings = .current) -> [String] {
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        var seen = Set<String>()
        return projects.filter { !$0.isArchived }.flatMap(\.folders)
            .filter { !settings.isIgnored($0) && seen.insert($0).inserted }
    }

    /// Where to read each folder's commits from: after the last one read, else from the start of today, so
    /// linking a repo picks up today's commits but not its history.
    @MainActor
    static func commitMarks(for folders: [String], defaults: UserDefaults = .standard, now: Date = .now) -> [(folder: String, after: Date)] {
        let marks = defaults.dictionary(forKey: commitMarksKey) as? [String: Double] ?? [:]
        let today = Calendar.current.startOfDay(for: now)
        return folders.map { ($0, marks[$0].map(Date.init(timeIntervalSince1970:)) ?? today) }
    }

    /// Adds commits as git beats, except for projects whose timer is running, and moves each folder's mark on.
    @MainActor
    static func ingestCommits(_ results: [(folder: String, after: Date, times: [Date])], context: ModelContext,
                              running: [TimeEntry], defaults: UserDefaults = .standard) {
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        let tracked = Set(running.filter(\.isRunning).compactMap { $0.task?.project?.persistentModelID })
        var marks = defaults.dictionary(forKey: commitMarksKey) as? [String: Double] ?? [:]
        for result in results {
            let times = result.times.filter { $0 > result.after }
            let skip = project(for: result.folder, in: projects).map { tracked.contains($0.persistentModelID) } ?? false
            if !skip {
                for time in times { context.insert(ActivityBeat(at: time, folder: result.folder, source: gitSource)) }
            }
            marks[result.folder] = (times.max() ?? result.after).timeIntervalSince1970
        }
        defaults.set(marks, forKey: commitMarksKey)
        try? context.save()
    }

    // MARK: Accept and dismiss

    /// Adds the suggestion's time and note to `task` on its day, onto that day's existing entry for the task if
    /// there is one, so a day's work on a task stays one record. Then clears the suggestion. With `remember`, the
    /// folder and task are saved on the project for next time.
    @MainActor @discardableResult
    static func accept(_ suggestion: Suggestion, task: TaskType, duration: TimeInterval? = nil, note: String? = nil,
                       remember: Bool, context: ModelContext) -> TimeEntry {
        let duration = max(0, duration ?? suggestion.roundedDuration)
        let note = note ?? suggestion.note
        let day = suggestion.day
        let existing = ((try? context.fetch(FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.date == day }))) ?? [])
            .filter { !$0.isLocked && $0.task?.persistentModelID == task.persistentModelID }
            .sorted { $0.createdAt > $1.createdAt }
            .first
        let entry: TimeEntry
        if let existing {
            existing.durationSeconds += duration
            existing.note = mergeNote(existing.note, adding: note)
            entry = existing
        } else {
            entry = TimeEntry(task: task, date: day, durationSeconds: duration, note: mergeNote("", adding: note))
            context.insert(entry)
        }
        if remember, let project = task.project {
            if suggestion.project == nil { project.folders.append(suggestion.folder) }
            if suggestion.project == nil || suggestion.project?.persistentModelID == project.persistentModelID {
                project.activityTaskID = task.uuid
            }
        }
        clear(suggestion, context: context)
        return entry
    }

    @MainActor
    static func dismiss(_ suggestion: Suggestion, context: ModelContext) {
        clear(suggestion, context: context)
    }

    /// Stops tracking a folder (and everything inside it), dropping what's already been collected there.
    @MainActor
    static func ignore(_ folder: String, context: ModelContext, defaults: UserDefaults = .standard) {
        ActivitySettings.setIgnored(folder, true, defaults: defaults)
        let settings = ActivitySettings.load(defaults)
        ((try? context.fetch(FetchDescriptor<ActivityBeat>())) ?? []).filter { settings.isIgnored($0.folder) }.forEach(context.delete)
        ((try? context.fetch(FetchDescriptor<ActivityNote>())) ?? []).filter { settings.isIgnored($0.folder) }.forEach(context.delete)
        try? context.save()
    }

    @MainActor
    private static func clear(_ suggestion: Suggestion, context: ModelContext) {
        suggestion.beats.forEach(context.delete)
        suggestion.notes.forEach(context.delete)
        try? context.save()
    }
}

/// Reads the activity inbox every minute, and linked repos' commits every five, while MyTime runs.
@MainActor
final class ActivityPoller {
    /// The running app's poller, so the Review tab can ask for fresh data.
    static weak var current: ActivityPoller?
    private let context: ModelContext
    private let timer: TimerService
    private var ticker: Timer?
    private var ticks = 0
    private var scanning = false

    init(context: ModelContext, timer: TimerService) {
        self.context = context
        self.timer = timer
    }

    func start() {
        Self.current = self
        poll(includingCommits: true)
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ticks += 1
                self.poll(includingCommits: self.ticks % 5 == 0)
            }
        }
    }

    func poll(includingCommits: Bool) {
        ActivityTracker.ingest(context: context, running: timer.activeEntries)
        if includingCommits { scanCommits() }
    }

    private func scanCommits() {
        guard !scanning else { return }
        let jobs = ActivityTracker.commitMarks(for: ActivityTracker.commitFolders(context: context))
        guard !jobs.isEmpty else { return }
        scanning = true
        Task.detached(priority: .utility) { [weak self] in
            let results = jobs.map { (folder: $0.folder, after: $0.after, times: GitLog.commitTimes(in: $0.folder, after: $0.after)) }
            await self?.finishScan(results)
        }
    }

    private func finishScan(_ results: [(folder: String, after: Date, times: [Date])]) {
        scanning = false
        ActivityTracker.ingestCommits(results, context: context, running: timer.activeEntries)
    }
}

/// Reads your own commit times from a repository.
enum GitLog {
    /// Commit times (committer date) after `after`, on any branch, by the repo's configured user.
    nonisolated static func commitTimes(in folder: String, after: Date) -> [Date] {
        guard let email = run(["-C", folder, "config", "user.email"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return [] }
        // A day's slack on --since; the exact cut is made on the parsed times.
        let since = ISO8601DateFormatter().string(from: after.addingTimeInterval(-86_400))
        guard let output = run(["-C", folder, "log", "--all", "--no-merges", "--since=\(since)",
                                "--author=\(email)", "--format=%ct"]) else { return [] }
        return output.split(separator: "\n").compactMap { Double($0).map(Date.init(timeIntervalSince1970:)) }
            .filter { $0 > after }
    }

    nonisolated private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = ["GIT_TERMINAL_PROMPT": "0", "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
