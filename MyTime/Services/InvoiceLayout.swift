import AppKit
import Foundation

/// Measures invoice rows and splits them into A4 pages. The page views and the PDF
/// both use this, so preview and PDF are identical.
enum InvoiceLayout {
    // A4 in points.
    static let pageSize = CGSize(width: 595, height: 842)
    static let margin: CGFloat = 40
    static var contentWidth: CGFloat { pageSize.width - margin * 2 }

    // Column widths (description takes the rest).
    static let typeWidth: CGFloat = 62
    static let quantityWidth: CGFloat = 52
    static let priceWidth: CGFloat = 72
    static let amountWidth: CGFloat = 78
    static let cellPadding: CGFloat = 6
    static var descriptionWidth: CGFloat {
        contentWidth - typeWidth - quantityWidth - priceWidth - amountWidth
    }

    // Fonts (sizes shared with the SwiftUI page views).
    static let bodySize: CGFloat = 9
    static let detailSize: CGFloat = 8
    static let groupSize: CGFloat = 9.5

    // Fixed block heights.
    static let firstPageHeaderHeight: CGFloat = 240
    static let tableHeaderHeight: CGFloat = 24
    static let footerHeight: CGFloat = 36
    static let rowVerticalPadding: CGFloat = 5

    enum Row: Equatable {
        case group(title: String, hours: Decimal, amount: Decimal)
        case line(index: Int, striped: Bool)
    }

    struct Page: Equatable {
        var number: Int
        var rows: [Row]
        var showsTotals: Bool
    }

    static func textHeight(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }

    static func height(of row: Row, lines: [InvoiceLine]) -> CGFloat {
        let width = descriptionWidth - cellPadding * 2
        switch row {
        case .group(let title, _, _):
            return textHeight(title, size: groupSize, weight: .semibold, width: width) + rowVerticalPadding * 2 + 2
        case .line(let index, _):
            let line = lines[index]
            var h = textHeight(line.lineDescription, size: bodySize, width: width)
            if !line.details.isEmpty {
                h += 2 + textHeight(line.details, size: detailSize, width: width)
            }
            return h + rowVerticalPadding * 2 + 2 // +2 for rounding slack and borders
        }
    }

    static func totalsHeight(notes: String) -> CGFloat {
        let notesHeight = notes.isEmpty ? 0 : 30 + textHeight(notes, size: bodySize, width: contentWidth - 12)
        return 110 + notesHeight
    }

    /// Group rows (project headings with subtotals) interleaved with line rows.
    static func rows(for lines: [InvoiceLine]) -> [Row] {
        var rows: [Row] = []
        var stripe = false
        for (index, line) in lines.enumerated() {
            if !line.groupTitle.isEmpty, index == 0 || lines[index - 1].groupTitle != line.groupTitle {
                let group = lines.filter { $0.groupTitle == line.groupTitle }
                rows.append(.group(title: line.groupTitle,
                                   hours: group.reduce(0) { $0 + ($1.quantity ?? 0) },
                                   amount: group.reduce(0) { $0 + $1.amount }))
                stripe = false
            }
            rows.append(.line(index: index, striped: stripe))
            stripe.toggle()
        }
        return rows
    }

    static func paginate(lines: [InvoiceLine], notes: String) -> [Page] {
        let rows = rows(for: lines)
        let bodyHeight = pageSize.height - margin * 2 - footerHeight
        var pages: [Page] = []
        var current: [Row] = []
        var remaining = bodyHeight - firstPageHeaderHeight - tableHeaderHeight

        func newPage() {
            pages.append(Page(number: pages.count + 1, rows: current, showsTotals: false))
            current = []
            remaining = bodyHeight - tableHeaderHeight
        }

        for (i, row) in rows.enumerated() {
            var needed = height(of: row, lines: lines)
            // Don't strand a project heading at the bottom of a page.
            if case .group = row, i + 1 < rows.count {
                needed += height(of: rows[i + 1], lines: lines)
            }
            if needed > remaining, !current.isEmpty { newPage() }
            current.append(row)
            remaining -= height(of: row, lines: lines)
        }

        if totalsHeight(notes: notes) > remaining, !current.isEmpty {
            newPage()
        }
        pages.append(Page(number: pages.count + 1, rows: current, showsTotals: true))
        return pages
    }
}
