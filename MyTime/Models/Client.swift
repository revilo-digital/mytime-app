import Foundation
import SwiftData

@Model
final class Client {
    var name: String
    var billingName: String
    var email: String
    var address: String
    var defaultRate: Decimal
    var isArchived: Bool
    var createdAt: Date
    /// Small square PNG, downscaled on import.
    @Attribute(.externalStorage) var logoData: Data?

    @Relationship(deleteRule: .cascade, inverse: \Project.client)
    var projects: [Project] = []

    init(name: String, defaultRate: Decimal = 0) {
        self.name = name
        self.billingName = name
        self.email = ""
        self.address = ""
        self.defaultRate = defaultRate
        self.isArchived = false
        self.createdAt = .now
    }
}
