import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Writes a suggestion's 1–3 word note ("Invoice layout") from what was worked on: the day's Claude Code session
/// titles and commit subjects. It uses Apple's on-device model, so nothing leaves the Mac. Without Apple Intelligence
/// there's no note, and you write your own.
@MainActor
final class NoteWriter {
    static let shared = NoteWriter()
    private static let cacheKey = "activityNoteCache"
    private static let cacheLimit = 300

    private let defaults: UserDefaults
    /// Notes already written, by what was worked on, so a card doesn't ask again on every redraw or relaunch.
    private var cache: [String: String]
    private var writing: [String: Task<String?, Never>] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cache = defaults.dictionary(forKey: Self.cacheKey) as? [String: String] ?? [:]
    }

    /// The note for this work, written once and then remembered. Nil if there's nothing to go on or the model
    /// isn't available.
    func note(for worked: [String]) async -> String? {
        guard !worked.isEmpty else { return nil }
        let key = worked.joined(separator: "\n")
        if let cached = cache[key] { return cached }
        if let task = writing[key] { return await task.value }
        let task = Task.detached(priority: .utility) { await Self.write(worked) }
        writing[key] = task
        let note = await task.value
        writing[key] = nil
        if let note {
            if cache.count >= Self.cacheLimit { cache.removeAll() }
            cache[key] = note
            defaults.set(cache, forKey: Self.cacheKey)
        }
        return note
    }

    /// Why notes can't be written on this Mac, or nil if they can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return "Writing notes needs macOS 26 or later." }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to have notes written for you."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready. Notes will be written once it has downloaded."
        case .unavailable(.deviceNotEligible):
            return "This Mac can't run Apple Intelligence, so notes aren't written for you."
        case .unavailable:
            return "Apple Intelligence isn't available, so notes aren't written for you."
        }
        #else
        return "Writing notes needs macOS 26 or later."
        #endif
    }

    nonisolated static let instructions = """
        You write the note for one line of a freelance software developer's invoice. You're given the titles of \
        the day's coding sessions and the day's commit messages for one project. Reply with two or three words \
        (never more) naming the main feature or piece of work, as the client would recognise it. Keep the \
        feature's own name when there is one. Good notes: "Invoice layout", "Login fixes", "Stripe checkout", \
        "Review tab", "Order history". Too vague: "Integration", "Updates", "Development". Don't use file names, \
        function names, ticket numbers, quotes or punctuation. Reply with only the note.
        """

    nonisolated private static func write(_ worked: [String]) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), case .available = SystemLanguageModel.default.availability else { return nil }
        let prompt = "The day's work:\n" + worked.prefix(20).map { "- " + $0.prefix(160) }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.2)
        guard var reply = try? await session.respond(to: prompt, options: options).content else { return nil }
        // The small model sometimes runs long; asked once more, it usually shortens it rather than cutting mid-phrase.
        if reply.split(whereSeparator: \.isWhitespace).count > ActivityTracker.maxLabelWords,
           let shorter = try? await session.respond(to: "Too long. Reply with the note in three words or fewer.",
                                                    options: options).content {
            reply = shorter
        }
        return clean(reply)
        #else
        return nil
        #endif
    }

    /// The model's reply as a note: its first line, without quotes, a "Note:" prefix or markdown, cut to three words.
    nonisolated static func clean(_ reply: String) -> String? {
        var text = reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        text = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "“", with: "").replacingOccurrences(of: "”", with: "")
        if let colon = text.firstIndex(of: ":"), text[..<colon].split(separator: " ").count <= 2 {
            text = String(text[text.index(after: colon)...])
        }
        let note = ActivityTracker.label(text)
        return note.isEmpty ? nil : note
    }
}
