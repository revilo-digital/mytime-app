import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BusinessSettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var settings: BusinessSettings?

    var body: some View {
        Group {
            if let settings {
                BusinessForm(settings: settings)
            } else {
                ProgressView()
            }
        }
        .onAppear { settings = BusinessSettings.current(in: context) }
        .onDisappear { try? context.save() }
    }
}

private struct BusinessForm: View {
    @Bindable var settings: BusinessSettings
    @State private var importingLogo = false

    var body: some View {
        Form {
            Section("Business") {
                TextField("Trading name", text: $settings.tradingName, prompt: Text("Jane Smith (trading as …)"))
                TextField("Address", text: $settings.address, axis: .vertical).lineLimit(2...5)
                TextField("Email", text: $settings.email)
                TextField("Phone", text: $settings.phone)
                TextField("GST number", text: $settings.gstNumber, prompt: Text("Leave blank if not GST registered"))
                TextField("Bank details", text: $settings.bankAccount, axis: .vertical)
                    .lineLimit(2...4)
                    .help("Shown in invoice notes and emails, e.g.\nName: …\nNumber: 12-3456-…")
            }
            Section("Logo") {
                HStack {
                    if let data = settings.logoData, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(height: 56)
                    } else {
                        Text("No logo").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…") { importingLogo = true }
                    if settings.logoData != nil {
                        Button("Remove") { settings.logoData = nil }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importingLogo, allowedContentTypes: [.png, .jpeg, .tiff, .pdf, .heic]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            settings.logoData = try? Data(contentsOf: url)
        }
    }
}

struct InvoiceSettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var settings: BusinessSettings?

    var body: some View {
        Group {
            if let settings {
                InvoiceSettingsForm(settings: settings)
            } else {
                ProgressView()
            }
        }
        .onAppear { settings = BusinessSettings.current(in: context) }
        .onDisappear { try? context.save() }
    }
}

private struct InvoiceSettingsForm: View {
    @Bindable var settings: BusinessSettings

    private var taxPercent: Binding<Decimal> {
        Binding(get: { settings.taxRate * 100 }, set: { settings.taxRate = $0 / 100 })
    }

    var body: some View {
        Form {
            Section("Numbering") {
                TextField("Prefix", text: $settings.invoicePrefix, prompt: Text("None"))
                TextField("Next number", value: $settings.nextInvoiceNumber, format: .number.grouping(.never))
                LabeledContent("Next invoice", value: "\(settings.invoicePrefix)\(settings.nextInvoiceNumber)")
            }
            Section("Defaults") {
                TextField("Subject", text: $settings.defaultSubject)
                Picker("Due date", selection: $settings.dueDateRule) {
                    ForEach(DueDateRule.allCases) { Text($0.label).tag($0) }
                }
                if settings.dueDateRule == .days {
                    Stepper("\(settings.paymentTermsDays) days", value: $settings.paymentTermsDays, in: 0...120)
                }
                DecimalField(title: "GST %", value: taxPercent)
                Picker("Round each entry up to", selection: $settings.roundingMinutes) {
                    Text("Don't round").tag(0)
                    Text("6 minutes").tag(6)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
            }
            Section {
                TextField("Notes", text: $settings.defaultInvoiceNotes, axis: .vertical).lineLimit(3...8)
            } header: {
                Text("Invoice notes")
            } footer: {
                Text("{gst} and {bank} are replaced with your business details.").font(.caption)
            }
            Section {
                MailFromField(settings: settings)
                TextField("Subject", text: $settings.emailSubjectTemplate)
                TextField("Body", text: $settings.emailBodyTemplate, axis: .vertical).lineLimit(4...12)
            } header: {
                Text("Email")
            } footer: {
                Text("Placeholders: {number} {client} {total} {due} {business} {bank}").font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

/// "Send from" address, with a picker filled from the accounts set up in Mail.
private struct MailFromField: View {
    @Bindable var settings: BusinessSettings
    @State private var accounts: [String] = []
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Send from", text: $settings.mailFromAddress, prompt: Text(settings.email.isEmpty ? "you@example.com" : settings.email))
                if accounts.isEmpty {
                    Button("Load from Mail") { load() }
                } else {
                    Menu("Mail accounts") {
                        ForEach(accounts, id: \.self) { address in
                            Button(address) { settings.mailFromAddress = address }
                        }
                    }
                    .fixedSize()
                }
            }
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
            } else if !settings.sendFromAddress.isEmpty, !accounts.isEmpty,
                      !accounts.contains(where: { $0.caseInsensitiveCompare(settings.sendFromAddress) == .orderedSame }) {
                Text("\(settings.sendFromAddress) isn't one of your Mail accounts, so Mail will use its default.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func load() {
        do {
            accounts = try InvoiceMailer.mailAccountAddresses()
            loadError = accounts.isEmpty ? "No accounts found in Mail." : nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
