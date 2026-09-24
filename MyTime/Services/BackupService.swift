import AppKit
import Foundation
import SQLite3
import SwiftData

/// Zipped copies of the store written to iCloud Drive (or any folder), plus restore.
///
/// A backup is `MyTime Backup <date>.zip` containing a consistent single-file copy of the
/// SQLite store (via `VACUUM INTO`), SwiftData's external data folder, and the invoice PDFs.
/// Restoring stages the backup and relaunches; the swap happens before the store is opened.
@MainActor
@Observable
final class BackupService {
    static let shared = BackupService()

    private enum Key {
        static let folder = "backupFolderPath"
        static let automatic = "backupAutomatic"
        static let keep = "backupKeepCount"
        static let last = "backupLastAt"
    }

    private let defaults = UserDefaults.standard
    private weak var container: ModelContainer?
    private var hourly: Timer?

    var isWorking = false
    var lastError: String?
    private(set) var lastBackup: Date?
    private(set) var backups: [URL] = []

    var automatic: Bool {
        didSet { defaults.set(automatic, forKey: Key.automatic) }
    }

    var keepCount: Int {
        didSet { defaults.set(keepCount, forKey: Key.keep); prune() }
    }

    var folder: URL {
        didSet { defaults.set(folder.path, forKey: Key.folder); refresh() }
    }

    private init() {
        automatic = defaults.object(forKey: Key.automatic) as? Bool ?? true
        keepCount = defaults.object(forKey: Key.keep) as? Int ?? 30
        lastBackup = defaults.object(forKey: Key.last) as? Date
        folder = defaults.string(forKey: Key.folder).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? BackupFiles.defaultFolder
        refresh()
    }

    // MARK: Folder

    static var iCloudDriveAvailable: Bool { BackupFiles.iCloudDrive != nil }

    var isInICloud: Bool {
        guard let drive = BackupFiles.iCloudDrive else { return false }
        return folder.standardizedFileURL.path.hasPrefix(drive.standardizedFileURL.path)
    }

    func refresh() {
        backups = BackupFiles.list(in: folder)
    }

    // MARK: Scheduling

    /// Called once at launch: backs up if due, then checks hourly.
    func start(container: ModelContainer) {
        self.container = container
        backUpIfDue()
        hourly?.invalidate()
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in BackupService.shared.backUpIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hourly = timer
    }

    func backUpIfDue() {
        guard automatic else { return }
        if let lastBackup, Date.now.timeIntervalSince(lastBackup) < 24 * 3600 { return }
        Task { await backUpNow() }
    }

    // MARK: Back up

    @discardableResult
    func backUpNow(label: String? = nil) async -> URL? {
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        try? container?.mainContext.save()

        let destination = folder
        let keep = keepCount
        do {
            let url = try await Task.detached(priority: .utility) {
                try BackupFiles.makeBackup(from: Persistence.supportDirectory, into: destination, label: label)
            }.value
            if label == nil {
                lastBackup = .now
                defaults.set(lastBackup, forKey: Key.last)
            }
            lastError = nil
            BackupFiles.prune(in: destination, keep: keep)
            refresh()
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func prune() {
        BackupFiles.prune(in: folder, keep: keepCount)
        refresh()
    }

    // MARK: Restore

    /// Validates the backup, saves a "Before restore" safety copy, stages it and relaunches.
    func restore(from backup: URL) async {
        isWorking = true
        do {
            let staged = try await Task.detached(priority: .userInitiated) {
                try BackupFiles.stageRestore(from: backup, supportDirectory: Persistence.supportDirectory)
            }.value
            isWorking = false
            // Safety copy of what's there now, in case the wrong backup was picked.
            _ = await backUpNow(label: "Before restore")
            _ = staged // swapped in by Persistence on the next launch
            Self.relaunch()
        } catch {
            isWorking = false
            lastError = error.localizedDescription
        }
    }

    private static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(filePath: "/bin/sh")
        // Wait for this process to exit so `open` launches a fresh copy rather than reactivating us.
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          path, String(ProcessInfo.processInfo.processIdentifier)]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// File-level backup work; nonisolated so it can run off the main thread.
enum BackupFiles {
    static let prefix = "MyTime Backup"
    static let storeName = "MyTime.store"
    static let pendingRestoreName = "PendingRestore"
    private static let copiedFolders = [".MyTime_SUPPORT", "Invoices"]

    static var iCloudDrive: URL? {
        let url = URL.homeDirectory.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var defaultFolder: URL {
        (iCloudDrive ?? URL.documentsDirectory).appending(path: "MyTime Backups", directoryHint: .isDirectory)
    }

    static func list(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "zip" }
            .sorted { created($0) > created($1) }
    }

    static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    static func fileName(label: String?, at date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_NZ")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: date)
        return label.map { "\(prefix) \(stamp) (\($0)).zip" } ?? "\(prefix) \(stamp).zip"
    }

    static func makeBackup(from support: URL, into folder: URL, label: String?) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let work = fm.temporaryDirectory.appending(path: "MyTimeBackup-\(UUID().uuidString)", directoryHint: .isDirectory)
        let payload = work.appending(path: "MyTime", directoryHint: .isDirectory)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        try snapshotStore(from: support.appending(path: storeName), to: payload.appending(path: storeName))
        for name in copiedFolders {
            let source = support.appending(path: name, directoryHint: .isDirectory)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: payload.appending(path: name, directoryHint: .isDirectory))
            }
        }
        let info: [String: String] = [
            "createdAt": ISO8601DateFormatter().string(from: .now),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "host": Host.current().localizedName ?? "",
        ]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            .write(to: payload.appending(path: "backup-info.json"))

        let zip = work.appending(path: "backup.zip")
        try ditto(["-c", "-k", "--norsrc", "--keepParent", payload.path, zip.path])

        let destination = folder.appending(path: fileName(label: label))
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: zip, to: destination)
        return destination
    }

    /// Consistent single-file copy of a live WAL-mode store.
    static func snapshotStore(from source: URL, to destination: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw BackupError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(db, "VACUUM INTO '\(escaped)'", nil, nil, nil) == SQLITE_OK else {
            throw BackupError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    static func prune(in folder: URL, keep: Int) {
        // Only automatic backups are pruned; labelled ones ("Before restore") are kept.
        let automatic = list(in: folder).filter { !$0.lastPathComponent.contains("(") }
        for old in automatic.dropFirst(max(keep, 1)) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// Unzips and checks a backup, then moves it to `PendingRestore` for the next launch.
    @discardableResult
    static func stageRestore(from zip: URL, supportDirectory: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "MyTimeRestore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try ditto(["-x", "-k", zip.path, work.path])

        let payload = work.appending(path: "MyTime", directoryHint: .isDirectory)
        let store = payload.appending(path: storeName)
        guard fm.fileExists(atPath: store.path) else { throw BackupError.notABackup }
        try validate(store: store)

        let pending = supportDirectory.appending(path: pendingRestoreName, directoryHint: .isDirectory)
        try? fm.removeItem(at: pending)
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try fm.moveItem(at: payload, to: pending)
        return pending
    }

    static func validate(store: URL) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw BackupError.notABackup }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE name = 'ZTIMEENTRY'", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 1 else {
            throw BackupError.notABackup
        }
    }

    /// Runs before the container opens: swaps a staged restore into place.
    /// The replaced files are moved aside to `Replaced <date>` rather than deleted.
    static func applyPendingRestore(in support: URL) {
        let fm = FileManager.default
        let pending = support.appending(path: pendingRestoreName, directoryHint: .isDirectory)
        guard fm.fileExists(atPath: pending.appending(path: storeName).path) else { return }

        let aside = support.appending(path: "Replaced \(fileName(label: nil).dropFirst(prefix.count + 1).dropLast(4))",
                                      directoryHint: .isDirectory)
        try? fm.createDirectory(at: aside, withIntermediateDirectories: true)
        let current = [storeName, "\(storeName)-wal", "\(storeName)-shm"] + copiedFolders
        for name in current {
            let item = support.appending(path: name)
            if fm.fileExists(atPath: item.path) { try? fm.moveItem(at: item, to: aside.appending(path: name)) }
        }
        for name in [storeName] + copiedFolders {
            let item = pending.appending(path: name)
            if fm.fileExists(atPath: item.path) { try? fm.moveItem(at: item, to: support.appending(path: name)) }
        }
        try? fm.removeItem(at: pending)
    }

    private static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BackupError.archive(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

enum BackupError: LocalizedError {
    case sqlite(String)
    case archive(String)
    case notABackup

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): "Couldn't copy the database: \(message)"
        case .archive(let message): "Couldn't write the archive: \(message)"
        case .notABackup: "That file isn't a MyTime backup."
        }
    }
}
