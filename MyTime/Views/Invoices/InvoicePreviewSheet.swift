import SwiftUI

struct InvoicePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let invoice: Invoice
    @State private var zoom: CGFloat = 1

    var body: some View {
        let lines = invoice.sortedLines
        let pages = InvoicePDF.pages(for: invoice)
        VStack(spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                VStack(spacing: 16) {
                    ForEach(pages, id: \.number) { page in
                        InvoicePageView(invoice: invoice, lines: lines, page: page, pageCount: pages.count)
                            .scaleEffect(zoom, anchor: .top)
                            .frame(width: InvoiceLayout.pageSize.width * zoom, height: InvoiceLayout.pageSize.height * zoom)
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack {
                Text("\(pages.count) page\(pages.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 0.6...1.6).frame(width: 140)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 720, height: 820)
    }
}
