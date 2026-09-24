import Foundation
import SwiftData

enum DueDateRule: String, Codable, CaseIterable, Identifiable {
    /// Due a set number of days after issue.
    case days
    /// Due on the 20th of the month after issue (common in NZ).
    case twentiethOfNextMonth
    var id: Self { self }

    var label: String {
        switch self {
        case .days: "Days after issue"
        case .twentiethOfNextMonth: "20th of the following month"
        }
    }
}

/// Your business details and invoicing preferences. There's exactly one row.
@Model
final class BusinessSettings {
    var tradingName: String
    var address: String
    var email: String
    var phone: String
    var gstNumber: String
    var bankAccount: String
    @Attribute(.externalStorage) var logoData: Data?
    var currencyCode: String
    var taxRate: Decimal
    var paymentTermsDays: Int
    var dueDateRuleRaw: String
    var defaultSubject: String
    var invoicePrefix: String
    var nextInvoiceNumber: Int
    /// Billing increment in minutes applied per entry at invoice time (0 = exact).
    var roundingMinutes: Int
    var defaultInvoiceNotes: String
    var emailSubjectTemplate: String
    var emailBodyTemplate: String
    /// Mail account address invoices are sent from; blank means the business email.
    var mailFromAddress: String = ""
    /// JSON of [DefaultTask]; nil means the recommended list.
    var defaultTasksData: Data? = nil

    var defaultTasks: [DefaultTask] {
        get { defaultTasksData.flatMap { try? JSONDecoder().decode([DefaultTask].self, from: $0) } ?? DefaultTask.recommended }
        set { defaultTasksData = try? JSONEncoder().encode(newValue) }
    }

    var sendFromAddress: String {
        let explicit = mailFromAddress.trimmingCharacters(in: .whitespaces)
        return explicit.isEmpty ? email.trimmingCharacters(in: .whitespaces) : explicit
    }

    init() {
        tradingName = ""
        address = ""
        email = ""
        phone = ""
        gstNumber = ""
        bankAccount = ""
        currencyCode = "NZD"
        taxRate = Decimal(string: "0.15")!
        paymentTermsDays = 14
        dueDateRuleRaw = DueDateRule.twentiethOfNextMonth.rawValue
        defaultSubject = "Contracting"
        invoicePrefix = ""
        nextInvoiceNumber = 1
        roundingMinutes = 0
        defaultInvoiceNotes = """
        GST Number: {gst}

        Payment by bank transfer to:

        {bank}
        """
        emailSubjectTemplate = "Invoice {number} from {business}"
        emailBodyTemplate = """
        Hi {client},

        Please find attached invoice {number} for {total}, due {due}.

        Payment can be made to {bank}.

        Thanks,
        {business}
        """
    }

    var dueDateRule: DueDateRule {
        get { DueDateRule(rawValue: dueDateRuleRaw) ?? .days }
        set { dueDateRuleRaw = newValue.rawValue }
    }

    func dueDate(forIssue issue: Date, calendar: Calendar = .current) -> Date {
        switch dueDateRule {
        case .days:
            return calendar.date(byAdding: .day, value: paymentTermsDays, to: issue) ?? issue
        case .twentiethOfNextMonth:
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: issue) ?? issue
            var parts = calendar.dateComponents([.year, .month], from: nextMonth)
            parts.day = 20
            return calendar.date(from: parts) ?? nextMonth
        }
    }

    /// Fills {gst}, {bank}, {business}, {email}, {phone} placeholders.
    func fill(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{gst}", with: gstNumber)
            .replacingOccurrences(of: "{bank}", with: bankAccount)
            .replacingOccurrences(of: "{business}", with: tradingName)
            .replacingOccurrences(of: "{email}", with: email)
            .replacingOccurrences(of: "{phone}", with: phone)
    }

    @MainActor
    static func current(in context: ModelContext) -> BusinessSettings {
        if let existing = try? context.fetch(FetchDescriptor<BusinessSettings>()).first {
            return existing
        }
        let settings = BusinessSettings()
        context.insert(settings)
        try? context.save()
        return settings
    }

    var snapshot: BusinessSnapshot {
        BusinessSnapshot(tradingName: tradingName, address: address, email: email, phone: phone,
                         gstNumber: gstNumber, bankAccount: bankAccount, logoData: logoData)
    }
}

/// Business details frozen onto an invoice when it's created.
struct BusinessSnapshot: Codable, Equatable {
    var tradingName: String
    var address: String
    var email: String
    var phone: String
    var gstNumber: String
    var bankAccount: String
    var logoData: Data?
}
