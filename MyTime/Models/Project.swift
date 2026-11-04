import Foundation
import SwiftData

enum BillingType: String, Codable, CaseIterable {
    case hourly
    case fixedFee
}

@Model
final class Project {
    var client: Client?
    /// Who the client is doing this work for, if anyone (e.g. Globex, through the agency Acme).
    var endClient: EndClient?
    var name: String
    var code: String
    var billingTypeRaw: String
    /// Agreed fee for fixed-fee projects; used as a budget, never auto-invoiced.
    var fixedFee: Decimal?
    var rateOverride: Decimal?
    var isBillable: Bool
    var isArchived: Bool
    var isFavourite: Bool
    var createdAt: Date
    /// Folders whose AI-tool activity belongs to this project, one path per line. Use `folders`.
    var activityFoldersRaw: String = ""
    /// The task that activity in those folders is suggested on.
    var activityTaskID: UUID?

    @Relationship(deleteRule: .cascade, inverse: \TaskType.project)
    var tasks: [TaskType] = []

    /// Agreed-fee lines invoiced for this project, which may have no time behind them.
    @Relationship(deleteRule: .nullify, inverse: \InvoiceLine.project)
    var invoiceLines: [InvoiceLine] = []

    /// "Globex – Spring Campaign": the name with its end client, for places that don't show the end client separately.
    var qualifiedName: String {
        endClient.map { "\($0.name) – \(name)" } ?? name
    }

    var billingType: BillingType {
        get { BillingType(rawValue: billingTypeRaw) ?? .hourly }
        set { billingTypeRaw = newValue.rawValue }
    }

    init(name: String, client: Client, billingType: BillingType = .hourly) {
        self.client = client
        self.name = name
        self.code = ""
        self.billingTypeRaw = billingType.rawValue
        self.isBillable = true
        self.isArchived = false
        self.isFavourite = false
        self.createdAt = .now
    }
}

extension Project {
    /// Standardised absolute paths, without duplicates.
    var folders: [String] {
        get { activityFoldersRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
        set {
            var seen = Set<String>()
            activityFoldersRaw = newValue.map(ActivityTracker.normalize).filter { seen.insert($0).inserted }.joined(separator: "\n")
        }
    }

    /// The task activity is suggested on, if it can still take time.
    var activityTask: TaskType? {
        guard let activityTaskID else { return nil }
        return tasks.first { $0.uuid == activityTaskID && $0.isSelectable }
    }

    /// The task to suggest activity on: the chosen one, else the one last tracked here, else one named
    /// "Development", else the first.
    var suggestedTask: TaskType? {
        if let activityTask { return activityTask }
        let usable = tasks.filter(\.isSelectable)
        let recent = usable.compactMap { task in task.entries.map(\.createdAt).max().map { (task, $0) } }
            .max { $0.1 < $1.1 }?.0
        return recent
            ?? usable.first { $0.name.localizedCaseInsensitiveContains("development") }
            ?? usable.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.first
    }
}
