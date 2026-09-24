import AppKit
import SwiftUI

@MainActor
enum InvoicePDF {
    static var directory: URL {
        Persistence.supportDirectory.appending(path: "Invoices", directoryHint: .isDirectory)
    }

    static func fileName(for invoice: Invoice) -> String {
        let client = invoice.clientBillingName.replacingOccurrences(of: "/", with: "-")
        return "Invoice \(invoice.number) – \(client).pdf"
    }

    static func pages(for invoice: Invoice) -> [InvoiceLayout.Page] {
        InvoiceLayout.paginate(lines: invoice.sortedLines, notes: invoice.notes)
    }

    /// Renders the invoice to a multi-page A4 PDF and returns its URL.
    @discardableResult
    static func write(_ invoice: Invoice, to url: URL? = nil) throws -> URL {
        let destination = url ?? directory.appending(path: fileName(for: invoice))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let lines = invoice.sortedLines
        let pages = pages(for: invoice)
        var mediaBox = CGRect(origin: .zero, size: InvoiceLayout.pageSize)
        let info = [kCGPDFContextTitle: "Invoice \(invoice.number)", kCGPDFContextCreator: "MyTime"] as CFDictionary
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, info) else {
            throw CocoaError(.fileWriteUnknown)
        }

        for page in pages {
            let renderer = ImageRenderer(content: InvoicePageView(invoice: invoice, lines: lines, page: page, pageCount: pages.count))
            renderer.proposedSize = ProposedViewSize(InvoiceLayout.pageSize)
            context.beginPDFPage(nil)
            renderer.render { _, draw in draw(context) }
            context.endPDFPage()
        }
        context.closePDF()
        return destination
    }
}
