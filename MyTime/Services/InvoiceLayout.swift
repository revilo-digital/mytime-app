import AppKit
import Foundation

/// What the layout needs to know about a line to place headings and subtotals. Saved invoice
/// lines and the New Invoice preview both lay out this way.
protocol InvoiceLayoutLine {
    var sectionTitle: String { get }
    var groupTitle: String { get }
    var amount: Decimal { get }
    /// Hours counted towards heading subtotals; none for fixed lines.
    var subtotalHours: Decimal { get }
}

extension InvoiceLine: InvoiceLayoutLine {
    var subtotalHours: Decimal { quantity ?? 0 }
}

extension LineSpec: InvoiceLayoutLine {
    var subtotalHours: Decimal { kind == .hourly ? hours : 0 }
}

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
    static let sectionSize: CGFloat = 10.5

    // Fixed block heights.
    static let firstPageHeaderHeight: CGFloat = 240
    static let tableHeaderHeight: CGFloat = 24
    static let footerHeight: CGFloat = 36
    static let rowVerticalPadding: CGFloat = 5

    enum Row: Equatable {
        /// End-client heading.
        case section(title: String, hours: Decimal, amount: Decimal)
        /// Project heading.
        case group(title: String, hours: Decimal, amount: Decimal)
        case line(index: Int, striped: Bool)

        var isHeading: Bool {
            if case .line = self { return false }
            return true
        }

        var isSection: Bool {
            if case .section = self { return true }
            return false
        }
    }

    /// Heading for lines outside every end-client section, e.g. a line added by hand.
    static let otherSection = "Other"

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
        case .section(let title, _, _):
            return textHeight(title, size: sectionSize, weight: .bold, width: width) + rowVerticalPadding * 2 + 4
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

    /// Section rows (end-client headings) and group rows (project headings), each with the subtotal
    /// of the run of lines beneath it, interleaved with line rows. Once any line has a section,
    /// lines without one go under "Other" so they don't read as part of the section above.
    static func rows<L: InvoiceLayoutLine>(for lines: [L]) -> [Row] {
        let sectioned = lines.contains { !$0.sectionTitle.isEmpty }
        let sections = lines.map { sectioned && $0.sectionTitle.isEmpty ? otherSection : $0.sectionTitle }

        func subtotal(from start: Int, while belongs: (Int) -> Bool) -> (hours: Decimal, amount: Decimal) {
            lines.indices[start...].prefix(while: belongs).reduce((Decimal(0), Decimal(0))) {
                ($0.0 + lines[$1].subtotalHours, $0.1 + lines[$1].amount)
            }
        }

        var rows: [Row] = []
        var stripe = false
        for (index, line) in lines.enumerated() {
            let newSection = sectioned && (index == 0 || sections[index - 1] != sections[index])
            if newSection {
                let sum = subtotal(from: index) { sections[$0] == sections[index] }
                rows.append(.section(title: sections[index], hours: sum.hours, amount: sum.amount))
                stripe = false
            }
            if !line.groupTitle.isEmpty, newSection || index == 0 || lines[index - 1].groupTitle != line.groupTitle {
                let sum = subtotal(from: index) { sections[$0] == sections[index] && lines[$0].groupTitle == line.groupTitle }
                rows.append(.group(title: line.groupTitle, hours: sum.hours, amount: sum.amount))
                stripe = false
            }
            rows.append(.line(index: index, striped: stripe))
            stripe.toggle()
        }
        return rows
    }

    /// The heading rows just before each line, for lists that step through lines rather than rows.
    static func headings<L: InvoiceLayoutLine>(for lines: [L]) -> [[Row]] {
        var result = Array(repeating: [Row](), count: lines.count)
        var pending: [Row] = []
        for row in rows(for: lines) {
            if case .line(let index, _) = row {
                result[index] = pending
                pending = []
            } else {
                pending.append(row)
            }
        }
        return result
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
            // Don't strand a heading at the bottom of a page: keep it with the first line beneath it.
            if row.isHeading {
                for next in rows[(i + 1)...] {
                    needed += height(of: next, lines: lines)
                    if !next.isHeading { break }
                }
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
