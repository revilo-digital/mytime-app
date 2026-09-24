import SwiftUI

/// One A4 page of an invoice, drawn at 1pt = 1px. Used for both preview and PDF.
struct InvoicePageView: View {
    let invoice: Invoice
    let lines: [InvoiceLine]
    let page: InvoiceLayout.Page
    let pageCount: Int

    private typealias L = InvoiceLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if page.number == 1 {
                FirstPageHeader(invoice: invoice)
                    .frame(height: L.firstPageHeaderHeight, alignment: .top)
            }
            if !page.rows.isEmpty {
                TableHeader().frame(height: L.tableHeaderHeight)
                ForEach(Array(page.rows.enumerated()), id: \.offset) { _, row in
                    rowView(row).frame(height: L.height(of: row, lines: lines))
                }
            }
            if page.showsTotals {
                TotalsBlock(invoice: invoice)
            }
            Spacer(minLength: 0)
            Text("Page \(page.number) of \(pageCount)")
                .font(.system(size: 9))
                .frame(maxWidth: .infinity)
                .frame(height: L.footerHeight, alignment: .bottom)
        }
        .padding(L.margin)
        .frame(width: L.pageSize.width, height: L.pageSize.height, alignment: .topLeading)
        .background(.white)
        .foregroundStyle(Color(white: 0.1))
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func rowView(_ row: InvoiceLayout.Row) -> some View {
        switch row {
        case .group(let title, let hours, let amount):
            GroupRow(title: title, hours: hours, amount: amount)
        case .line(let index, let striped):
            LineRowView(line: lines[index], striped: striped, indented: !lines[index].groupTitle.isEmpty)
        }
    }
}

// MARK: - Header

private struct FirstPageHeader: View {
    let invoice: Invoice
    private var business: BusinessSnapshot? { invoice.business }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                logo.frame(width: 220, height: 70, alignment: .topLeading)
                Spacer()
                VStack(alignment: .leading, spacing: 18) {
                    Text(business?.gstNumber.isEmpty == false ? "TAX INVOICE" : "INVOICE")
                        .font(.system(size: 20, weight: .semibold))
                    LabeledBlock(label: "From") {
                        Text(business?.tradingName ?? "").font(.system(size: 11, weight: .semibold))
                        Text(business?.address ?? "").font(.system(size: 9.5))
                    }
                }
                .frame(width: 250, alignment: .leading)
            }
            .frame(height: 140, alignment: .top)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    FieldRow(label: "Invoice ID", value: invoice.number, bold: true)
                    FieldRow(label: "Issue Date", value: DateText.short(invoice.issueDate))
                    FieldRow(label: "Due Date", value: DateText.short(invoice.dueDate))
                    if !invoice.subject.isEmpty {
                        FieldRow(label: "Subject", value: invoice.subject)
                    }
                }
                .frame(width: 250, alignment: .leading)
                Spacer()
                LabeledBlock(label: "Invoice For") {
                    Text(invoice.clientBillingName).font(.system(size: 11, weight: .semibold))
                    if !invoice.clientAddress.isEmpty {
                        Text(invoice.clientAddress).font(.system(size: 9.5))
                    }
                }
                .frame(width: 250, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var logo: some View {
        if let data = business?.logoData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFit()
        }
    }
}

private struct LabeledBlock<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 9)).foregroundStyle(.gray).frame(width: 60, alignment: .trailing)
            Rectangle().fill(Color(white: 0.8)).frame(width: 1)
            VStack(alignment: .leading, spacing: 2) { content }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FieldRow: View {
    let label: String
    let value: String
    var bold = false

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 9)).foregroundStyle(.gray).frame(width: 70, alignment: .leading)
            Rectangle().fill(Color(white: 0.8)).frame(width: 1)
            Text(value).font(.system(size: 9.5, weight: bold ? .semibold : .regular))
        }
        .frame(height: 20)
    }
}

// MARK: - Table

private struct TableHeader: View {
    private typealias L = InvoiceLayout

    var body: some View {
        HStack(spacing: 0) {
            Cell(width: L.typeWidth) { Text("Item Type") }
            Cell(width: L.descriptionWidth) { Text("Description") }
            Cell(width: L.quantityWidth, alignment: .trailing) { Text("Quantity") }
            Cell(width: L.priceWidth, alignment: .trailing) { Text("Unit Price") }
            Cell(width: L.amountWidth, alignment: .trailing, border: false) { Text("Amount") }
        }
        .font(.system(size: 8.5, weight: .semibold))
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.7)).frame(height: 1) }
    }
}

private struct GroupRow: View {
    let title: String
    let hours: Decimal
    let amount: Decimal
    private typealias L = InvoiceLayout

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: L.groupSize, weight: .semibold))
                .padding(.horizontal, L.cellPadding)
                .frame(width: L.typeWidth + L.descriptionWidth, alignment: .leading)
            Text(HoursFormat.clock(hours))
                .padding(.horizontal, L.cellPadding)
                .frame(width: L.quantityWidth, alignment: .trailing)
            Spacer().frame(width: L.priceWidth)
            Text(Money.format(amount))
                .padding(.horizontal, L.cellPadding)
                .frame(width: L.amountWidth, alignment: .trailing)
        }
        .font(.system(size: L.groupSize, weight: .semibold))
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.9))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.8)).frame(height: 1) }
    }
}

private struct LineRowView: View {
    let line: InvoiceLine
    let striped: Bool
    let indented: Bool
    private typealias L = InvoiceLayout

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Cell(width: L.typeWidth) { Text("Service") }
            Cell(width: L.descriptionWidth) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.lineDescription)
                    if !line.details.isEmpty {
                        Text(line.details).font(.system(size: L.detailSize)).foregroundStyle(.gray)
                    }
                }
            }
            Cell(width: L.quantityWidth, alignment: .trailing) {
                Text(line.kind == .hourly ? HoursFormat.clock(line.quantity ?? 0) : "1")
            }
            Cell(width: L.priceWidth, alignment: .trailing) { Text(Money.format(line.unitPrice)) }
            Cell(width: L.amountWidth, alignment: .trailing, border: false) {
                Text(Money.format(line.amount)).fontWeight(.semibold)
            }
        }
        .font(.system(size: L.bodySize))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(striped ? Color(white: 0.95) : .white)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.8)).frame(height: 1) }
    }
}

private struct Cell<Content: View>: View {
    let width: CGFloat
    var alignment: Alignment = .leading
    var border = true
    @ViewBuilder var content: Content
    private typealias L = InvoiceLayout

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, L.cellPadding)
            .padding(.vertical, L.rowVerticalPadding)
            .frame(width: width, alignment: alignment)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .trailing) {
                if border { Rectangle().fill(Color(white: 0.8)).frame(width: 1) }
            }
    }
}

// MARK: - Totals

private struct TotalsBlock: View {
    let invoice: Invoice

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                if invoice.totalHours > 0 {
                    (Text("Total hours: ") + Text(HoursFormat.long(invoice.totalHours)).bold())
                        .font(.system(size: 11))
                }
                Spacer()
                Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        Text("Subtotal").foregroundStyle(.gray)
                        Text(Money.format(invoice.subtotal))
                    }
                    if invoice.taxRate > 0 {
                        GridRow {
                            Text("GST (\(TaxFormat.percent(invoice.taxRate)))").foregroundStyle(.gray)
                            Text(Money.format(invoice.taxAmount))
                        }
                    }
                    GridRow {
                        Text("Amount Due").font(.system(size: 11, weight: .bold))
                        Text(Money.format(invoice.total)).font(.system(size: 12))
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 9.5))
                .padding(.trailing, InvoiceLayout.cellPadding)
            }
            .padding(.top, 16)

            if !invoice.notes.isEmpty {
                Rectangle().fill(Color(white: 0.8)).frame(height: 1).padding(.top, 24)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes").font(.system(size: 8.5, weight: .semibold))
                    Text(invoice.notes).font(.system(size: InvoiceLayout.bodySize))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6)
                .padding(.top, 8)
            }
        }
        .monospacedDigit()
    }
}

enum DateText {
    /// "23/09/2026"
    static func short(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_NZ")
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: date)
    }
}
