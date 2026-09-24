import SwiftData
import SwiftUI

enum InvoiceFilter: String, CaseIterable, Identifiable {
    case all = "All", draft = "Draft", outstanding = "Outstanding", paid = "Paid"
    var id: Self { self }

    func includes(_ invoice: Invoice) -> Bool {
        switch self {
        case .all: true
        case .draft: invoice.status == .draft
        case .outstanding: invoice.status == .sent
        case .paid: invoice.status == .paid
        }
    }
}

struct InvoicesView: View {
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @State private var selection: Invoice?
    @State private var filter: InvoiceFilter = .all
    @State private var showingNew = false
    @State private var search = ""

    private var filtered: [Invoice] {
        invoices.filter(filter.includes).filter {
            search.isEmpty || $0.number.localizedCaseInsensitiveContains(search)
                || $0.clientBillingName.localizedCaseInsensitiveContains(search)
        }
    }

    private var outstanding: [Invoice] { invoices.filter { $0.status == .sent } }
    private var overdueTotal: Decimal { outstanding.filter(\.isOverdue).reduce(0) { $0 + $1.total } }
    private var outstandingTotal: Decimal { outstanding.reduce(0) { $0 + $1.total } }

    private var paidThisYear: Decimal {
        let start = Calendar.current.dateInterval(of: .year, for: .now)?.start ?? .now
        return invoices.filter { $0.status == .paid && ($0.paidAt ?? $0.issueDate) >= start }.reduce(0) { $0 + $1.total }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { invoice in
                InvoiceRow(invoice: invoice).tag(invoice)
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Search invoices")
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        MiniStat(title: "Outstanding", value: outstandingTotal, color: .orange)
                        MiniStat(title: "Overdue", value: overdueTotal, color: overdueTotal > 0 ? .red : .secondary)
                        MiniStat(title: "Paid this year", value: paidThisYear, color: .green)
                    }
                    Picker("Filter", selection: $filter) {
                        ForEach(InvoiceFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(12)
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { showingNew = true } label: { Label("New Invoice", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Text("\(filtered.count) invoice\(filtered.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.bar)
            }
        } detail: {
            if let selection {
                InvoiceDetailView(invoice: selection, onDelete: { self.selection = nil })
                    .id(selection.persistentModelID)
            } else {
                ContentUnavailableView {
                    Label("No Invoice Selected", systemImage: "doc.text")
                } description: {
                    Text("Pick an invoice, or create one from unbilled time.")
                } actions: {
                    Button("New Invoice") { showingNew = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showingNew) {
            NewInvoiceSheet { created in selection = created }
        }
    }
}

private struct MiniStat: View {
    let title: String
    let value: Decimal
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(color).lineLimit(1)
            Text(Money.format(value))
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .card(padding: 8, cornerRadius: 10, tint: color == .secondary ? nil : color)
    }
}

private struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: invoice.clientBillingName, size: 30, imageData: invoice.client?.logoData)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(invoice.number).font(.body.weight(.semibold))
                    StatusBadge(invoice: invoice)
                }
                Text(invoice.clientBillingName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(invoice.total)).font(.body.weight(.medium)).monospacedDigit()
                Text(invoice.issueDate.formatted(.dateTime.day().month(.abbreviated).year(.twoDigits)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusBadge: View {
    let invoice: Invoice

    var body: some View {
        let (text, color): (String, Color) = switch invoice.status {
        case .draft: ("Draft", .secondary)
        case .sent: invoice.isOverdue ? ("Overdue", .red) : ("Sent", .orange)
        case .paid: ("Paid", .green)
        }
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.12), in: .capsule)
    }
}
