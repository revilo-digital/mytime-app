import AppKit

@MainActor
enum InvoiceMailer {
    static func fill(_ template: String, invoice: Invoice) -> String {
        let business = invoice.business
        return template
            .replacingOccurrences(of: "{number}", with: invoice.number)
            .replacingOccurrences(of: "{client}", with: invoice.clientBillingName)
            .replacingOccurrences(of: "{total}", with: Money.format(invoice.total))
            .replacingOccurrences(of: "{due}", with: DateText.short(invoice.dueDate))
            .replacingOccurrences(of: "{business}", with: business?.tradingName ?? "")
            .replacingOccurrences(of: "{bank}", with: business?.bankAccount ?? "")
    }

    /// Opens a Mail draft with the PDF attached. Returns false if no mail app is available.
    ///
    /// When a send-from address is set, Mail is scripted directly so the draft uses that
    /// account; otherwise (or if scripting is refused) it falls back to the system share sheet,
    /// which always uses Mail's default account.
    static func compose(_ invoice: Invoice, settings: BusinessSettings) throws -> Bool {
        let pdf = try InvoicePDF.write(invoice)
        let subject = fill(settings.emailSubjectTemplate, invoice: invoice)
        let body = fill(settings.emailBodyTemplate, invoice: invoice)

        if !settings.sendFromAddress.isEmpty {
            do {
                try composeInMail(from: settings.sendFromAddress, to: invoice.clientEmail,
                                  subject: subject, body: body, attachment: pdf)
                return true
            } catch MailScriptError.notAuthorised {
                // Automation permission refused — still let them send via the default account.
            } catch {
                // Fall through to the share sheet.
            }
        }

        guard let service = NSSharingService(named: .composeEmail) else { return false }
        service.recipients = invoice.clientEmail.isEmpty ? [] : [invoice.clientEmail]
        service.subject = subject
        guard service.canPerform(withItems: [body, pdf]) else { return false }
        service.perform(withItems: [body, pdf])
        return true
    }

    // MARK: Mail scripting

    static func composeInMail(from sender: String, to recipient: String, subject: String, body: String, attachment: URL) throws {
        let recipientLine = recipient.isEmpty ? "" :
            "make new to recipient at end of to recipients with properties {address:\(quoted(recipient))}"
        let source = """
        tell application "Mail"
            set msg to make new outgoing message with properties {subject:\(quoted(subject)), content:\(quoted(body) + " & return & return"), visible:true}
            tell msg
                set sender to \(quoted(sender))
                \(recipientLine)
                tell content to make new attachment with properties {file name:(POSIX file \(quoted(attachment.path)))} at after the last paragraph
            end tell
            activate
        end tell
        """
        try run(source)
    }

    /// Every address of every account configured in Mail.
    static func mailAccountAddresses() throws -> [String] {
        let result = try run("""
        tell application "Mail"
            set out to {}
            repeat with acct in every account
                repeat with addr in (email addresses of acct)
                    set end of out to (addr as text)
                end repeat
            end repeat
            return out
        end tell
        """)
        guard let result, result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
    }

    @discardableResult
    private static func run(_ source: String) throws -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { throw MailScriptError.failed("Couldn't build the script.") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 { throw MailScriptError.notAuthorised }
            throw MailScriptError.failed(error[NSAppleScript.errorMessage] as? String ?? "Mail error \(code)")
        }
        return result
    }

    /// AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum MailScriptError: LocalizedError {
    case notAuthorised
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorised: "MyTime isn't allowed to control Mail. Turn it on in System Settings › Privacy & Security › Automation."
        case .failed(let message): message
        }
    }
}
