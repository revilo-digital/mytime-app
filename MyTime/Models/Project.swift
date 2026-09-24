import Foundation
import SwiftData

enum BillingType: String, Codable, CaseIterable {
    case hourly
    case fixedFee
}

@Model
final class Project {
    var client: Client?
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

    @Relationship(deleteRule: .cascade, inverse: \TaskType.project)
    var tasks: [TaskType] = []

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
