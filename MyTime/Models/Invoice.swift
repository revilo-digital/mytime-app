import Foundation
import SwiftData

enum InvoiceStatus: String, Codable, CaseIterable {
    case draft, sent, paid
}

@Model
final class Invoice {
    var number: String
    var subject: String = ""
    var statusRaw: String
    var client: Client?
    var issueDate: Date
    var dueDate: Date
    // Snapshots, so later edits to the client or business don't change a sent invoice.
    var clientBillingName: String
    var clientAddress: String
    var clientEmail: String
    var businessSnapshot: Data?
    var taxRate: Decimal
    var subtotal: Decimal
    var taxAmount: Decimal
    var total: Decimal
    var notes: String
    var sentAt: Date?
    var paidAt: Date?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \InvoiceLine.invoice)
    var lines: [InvoiceLine] = []

    @Relationship(deleteRule: .nullify, inverse: \TimeEntry.invoice)
    var entries: [TimeEntry] = []

    var status: InvoiceStatus {
        get { InvoiceStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    var business: BusinessSnapshot? {
        get { businessSnapshot.flatMap { try? JSONDecoder().decode(BusinessSnapshot.self, from: $0) } }
        set { businessSnapshot = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var sortedLines: [InvoiceLine] { lines.sorted { $0.sortOrder < $1.sortOrder } }

    var isEditable: Bool { status == .draft }

    /// Sum of hourly line quantities, e.g. for "Total hours: 26h 45min".
    var totalHours: Decimal {
        lines.filter { $0.kind == .hourly }.reduce(0) { $0 + ($1.quantity ?? 0) }
    }

    var isOverdue: Bool { status == .sent && dueDate < Calendar.current.startOfDay(for: .now) }

    init(client: Client, issueDate: Date, dueDate: Date, taxRate: Decimal) {
        self.number = ""
        self.subject = ""
        self.statusRaw = InvoiceStatus.draft.rawValue
        self.client = client
        self.issueDate = issueDate
        self.dueDate = dueDate
        self.clientBillingName = client.billingName
        self.clientAddress = client.address
        self.clientEmail = client.email
        self.taxRate = taxRate
        self.subtotal = 0
        self.taxAmount = 0
        self.total = 0
        self.notes = ""
        self.createdAt = .now
    }
}

enum InvoiceLineKind: String, Codable {
    case hourly, fixed
}

@Model
final class InvoiceLine {
    var invoice: Invoice?
    var kindRaw: String
    var lineDescription: String
    /// Heading this line sits under on the invoice (the project name), or empty for none.
    var groupTitle: String = ""
    /// Secondary text under the description, e.g. deduplicated entry notes.
    var details: String = ""
    /// Hours for hourly lines; nil for fixed lines.
    var quantity: Decimal?
    var unitPrice: Decimal
    var amount: Decimal
    var sortOrder: Int

    var kind: InvoiceLineKind {
        get { InvoiceLineKind(rawValue: kindRaw) ?? .fixed }
        set { kindRaw = newValue.rawValue }
    }

    init(kind: InvoiceLineKind, description: String, quantity: Decimal?, unitPrice: Decimal, amount: Decimal, sortOrder: Int,
         groupTitle: String = "", details: String = "") {
        self.kindRaw = kind.rawValue
        self.lineDescription = description
        self.groupTitle = groupTitle
        self.details = details
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.amount = amount
        self.sortOrder = sortOrder
    }
}
