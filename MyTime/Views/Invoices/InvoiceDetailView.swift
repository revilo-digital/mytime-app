import SwiftData
import SwiftUI

struct InvoiceDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var invoice: Invoice
    var onDelete: () -> Void

    @State private var confirmDelete = false
    @State private var showEntries = false
    @State private var showPreview = false
    @State private var askMarkSent = false
    @State private var errorMessage: String?

    private var editable: Bool { invoice.isEditable }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                detailsCard
                linesCard
                totalsCard
                notesCard
                entriesCard
                if editable {
                    HStack {
                        Text("Deleting a draft returns its time to unbilled.").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete Draft…", role: .destructive) { confirmDelete = true }
                    }
                    .card(padding: 16)
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Invoice \(invoice.number)")
        .toolbar { toolbar }
        .onChange(of: invoice.lines.map(\.unitPrice)) { InvoiceBuilder.recalculate(invoice) }
        .onChange(of: invoice.lines.map { $0.quantity ?? 0 }) { InvoiceBuilder.recalculate(invoice) }
        .onChange(of: invoice.taxRate) { InvoiceBuilder.recalculate(invoice) }
        .onDisappear { try? context.save() }
        .sheet(isPresented: $showPreview) { InvoicePreviewSheet(invoice: invoice) }
        .alert("Mark invoice \(invoice.number) as sent?", isPresented: $askMarkSent) {
            Button("Mark as Sent") { InvoiceBuilder.setStatus(.sent, on: invoice) }
            Button("Not Yet", role: .cancel) {}
        } message: {
            Text("Do this once you've sent the email from Mail.")
        }
        .alert("Couldn't create the invoice", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Delete draft invoice \(invoice.number)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                InvoiceBuilder.deleteDraft(invoice, settings: BusinessSettings.current(in: context), context: context)
                onDelete()
            }
        } message: {
            Text("\(invoice.entries.count) time entries will return to unbilled.")
        }
    }

    // MARK: Hero

    private var statusTint: Color {
        switch invoice.status {
        case .draft: .secondary
        case .sent: invoice.isOverdue ? .red : .orange
        case .paid: .green
        }
    }

    private var statusLine: String {
        switch invoice.status {
        case .draft: "Draft, not sent yet"
        case .sent:
            (invoice.isOverdue ? "Overdue, was due " : "Due ") + invoice.dueDate.formatted(date: .abbreviated, time: .omitted)
        case .paid: "Paid " + (invoice.paidAt ?? .now).formatted(date: .abbreviated, time: .omitted)
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            Avatar(name: invoice.clientBillingName, size: 56, imageData: invoice.client?.logoData)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Invoice \(invoice.number)").font(.system(size: 26, weight: .semibold))
                    StatusBadge(invoice: invoice)
                }
                Text(invoice.clientBillingName + (invoice.subject.isEmpty ? "" : " · \(invoice.subject)"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(invoice.status == .paid ? "Amount Paid" : "Amount Due").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(Money.format(invoice.total))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(statusLine).font(.caption.weight(.medium)).foregroundStyle(statusTint)
            }
        }
        .card(padding: 20, tint: invoice.status == .draft ? nil : statusTint)
    }

    // MARK: Details

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Details")
            HStack(alignment: .top, spacing: 28) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    DetailField(label: "Invoice ID") { TextField("Number", text: $invoice.number).frame(width: 110) }
                    DetailField(label: "Issue date") {
                        DatePicker("Issue date", selection: $invoice.issueDate, displayedComponents: .date).labelsHidden()
                    }
                    DetailField(label: "Due date") {
                        DatePicker("Due date", selection: $invoice.dueDate, displayedComponents: .date).labelsHidden()
                    }
                    DetailField(label: "Subject") { TextField("Subject", text: $invoice.subject) }
                }
                .frame(maxWidth: .infinity)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    DetailField(label: "Invoice for") { TextField("Billing name", text: $invoice.clientBillingName) }
                    DetailField(label: "Address") {
                        TextField("Address", text: $invoice.clientAddress, axis: .vertical).lineLimit(1...4)
                    }
                    DetailField(label: "Email") { TextField("Email", text: $invoice.clientEmail) }
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!editable)
            .card(padding: 20)
        }
    }

    // MARK: Lines

    private var linesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Lines") {
                if editable {
                    Button {
                        let line = InvoiceLine(kind: .fixed, description: "", quantity: nil, unitPrice: 0, amount: 0,
                                               sortOrder: (invoice.lines.map(\.sortOrder).max() ?? -1) + 1)
                        line.invoice = invoice
                        context.insert(line)
                    } label: { Label("Add fixed line", systemImage: "plus") }
                        .buttonStyle(.bordered)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                let lines = invoice.sortedLines
                if lines.isEmpty {
                    Text("No lines yet").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(20)
                }
                ForEach(Array(lines.enumerated()), id: \.element.persistentModelID) { index, line in
                    if !line.groupTitle.isEmpty, index == 0 || lines[index - 1].groupTitle != line.groupTitle {
                        GroupHeaderRow(title: line.groupTitle, lines: lines.filter { $0.groupTitle == line.groupTitle })
                            .padding(.top, index == 0 ? 0 : 14)
                            .padding(.bottom, 4)
                    }
                    LineRow(line: line, editable: editable) {
                        context.delete(line)
                        invoice.lines.removeAll { $0.persistentModelID == line.persistentModelID }
                        InvoiceBuilder.recalculate(invoice)
                    }
                    .padding(.vertical, 6)
                    if index < lines.count - 1 { Divider().opacity(0.5) }
                }
            }
            .card(padding: 20)
        }
    }

    private var totalsCard: some View {
        HStack {
            Spacer()
            Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("Total hours").foregroundStyle(.secondary)
                    Text(HoursFormat.long(invoice.totalHours))
                }
                GridRow {
                    Text("Subtotal").foregroundStyle(.secondary)
                    Text(Money.format(invoice.subtotal))
                }
                GridRow {
                    Text("GST (\(TaxFormat.percent(invoice.taxRate)))").foregroundStyle(.secondary)
                    Text(Money.format(invoice.taxAmount))
                }
                Divider().gridCellColumns(2)
                GridRow {
                    Text("Amount Due").font(.title3.weight(.semibold))
                    Text(Money.format(invoice.total)).font(.system(.title2, design: .rounded).weight(.bold))
                }
            }
            .monospacedDigit()
            .frame(width: 320)
        }
        .card(padding: 20)
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Notes")
            TextField("Payment details, thanks, etc.", text: $invoice.notes, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...10)
                .disabled(!editable)
                .card(padding: 14)
        }
    }

    private var entriesCard: some View {
        let billed = invoice.entries.filter { $0.billingState == .billed }
        let covered = invoice.entries.filter { $0.billingState == .covered }
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Time on this invoice")
            DisclosureGroup(isExpanded: $showEntries) {
                VStack(spacing: 6) {
                    ForEach(invoice.entries.sorted { $0.date < $1.date }) { entry in
                        HStack {
                            Text(entry.date.formatted(.dateTime.day().month(.abbreviated)))
                                .foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                            Text(entry.task?.shortPath ?? "")
                            if !entry.note.isEmpty { Text(entry.note).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            if entry.billingState == .covered { Tag(text: "Covered", color: .purple) }
                            Text(DurationFormat.short(entry.liveDuration())).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Tag(text: "\(billed.count) billed", color: .blue)
                    Tag(text: "\(covered.count) covered", color: .purple)
                    Text("\(DurationFormat.short(BillingSummary.totalSeconds(invoice.entries))) tracked")
                        .foregroundStyle(.secondary)
                }
            }
            .card(padding: 14)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Preview", systemImage: "eye") { save(); showPreview = true }
            Menu("PDF", systemImage: "doc.richtext") {
                Button("Open in Preview") { run { NSWorkspace.shared.open(try InvoicePDF.write(invoice)) } }
                Button("Save As…") { saveAs() }
                Button("Show in Finder") { run { NSWorkspace.shared.activateFileViewerSelecting([try InvoicePDF.write(invoice)]) } }
            }
            Button { email() } label: {
                Label("Email…", systemImage: "envelope").labelStyle(.titleAndIcon)
            }
            .help("Opens a Mail draft with the PDF attached, then asks whether to mark it as sent")
        }
        ToolbarItemGroup {
            switch invoice.status {
            case .draft:
                Button { InvoiceBuilder.setStatus(.sent, on: invoice) } label: {
                    Label("Mark as Sent", systemImage: "checkmark.circle").labelStyle(.titleAndIcon)
                }
                .help("Change the status to Sent without emailing — e.g. if you sent it another way")
            case .sent:
                Button { InvoiceBuilder.setStatus(.paid, on: invoice) } label: {
                    Label("Mark as Paid", systemImage: "checkmark.seal").labelStyle(.titleAndIcon)
                }
                .help("Record that this invoice has been paid")
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Revert to Draft") { InvoiceBuilder.setStatus(.draft, on: invoice) }
                }
            case .paid:
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Mark as Unpaid") { InvoiceBuilder.setStatus(.sent, on: invoice) }
                }
            }
        }
    }
}

extension InvoiceDetailView {
    private func save() {
        InvoiceBuilder.recalculate(invoice)
        try? context.save()
    }

    private func run(_ action: () throws -> Void) {
        save()
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    private func saveAs() {
        save()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = InvoicePDF.fileName(for: invoice)
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try InvoicePDF.write(invoice, to: url) }
    }

    private func email() {
        run {
            let settings = BusinessSettings.current(in: context)
            if try InvoiceMailer.compose(invoice, settings: settings) {
                if invoice.status == .draft { askMarkSent = true }
            } else {
                errorMessage = "No email app is set up. Add your account to Mail in System Settings → Internet Accounts."
            }
        }
    }
}

private struct GroupHeaderRow: View {
    let title: String
    let lines: [InvoiceLine]

    var body: some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(.tint)
            Spacer()
            Text(HoursFormat.clock(lines.reduce(0) { $0 + ($1.quantity ?? 0) })).foregroundStyle(.secondary)
            Text(Money.format(lines.reduce(0) { $0 + $1.amount })).bold().frame(width: 100, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.top, 6)
    }
}

private struct LineRow: View {
    @Bindable var line: InvoiceLine
    let editable: Bool
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Description", text: $line.lineDescription, axis: .vertical).labelsHidden()
                if !line.details.isEmpty || editable {
                    TextField("Details", text: $line.details, axis: .vertical)
                        .labelsHidden()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, line.groupTitle.isEmpty ? 0 : 12)
            if line.kind == .hourly {
                HoursField(hours: $line.quantity).labelsHidden().frame(width: 64)
                    .multilineTextAlignment(.trailing)
                Text("×").foregroundStyle(.secondary)
                DecimalField(title: "Rate", value: $line.unitPrice).labelsHidden().frame(width: 80)
                    .multilineTextAlignment(.trailing)
            } else {
                Text("Fixed").font(.caption).foregroundStyle(.secondary)
                DecimalField(title: "Amount", value: $line.unitPrice).labelsHidden().frame(width: 100)
                    .multilineTextAlignment(.trailing)
            }
            Text(Money.format(line.amount)).bold().monospacedDigit().frame(width: 100, alignment: .trailing)
            if editable {
                Button(action: onDelete) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        .disabled(!editable)
    }
}
