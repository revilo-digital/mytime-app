import Foundation
import PDFKit
import SwiftData
import Testing
@testable import MyTime

@MainActor
struct InvoicePDFTests {
    let container: ModelContainer
    let context: ModelContext
    let client: Client
    let settings: BusinessSettings

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        client = Client(name: "Acme", defaultRate: 150)
        context.insert(client)
        settings = BusinessSettings.current(in: context)
        settings.tradingName = "Test Trader"
        settings.gstNumber = "000-000-000"
        settings.bankAccount = "Name: Test\nNumber: 00-0000"
    }

    private func invoice(lineCount: Int, projects: Int = 3) -> Invoice {
        var entries: [TimeEntry] = []
        for p in 0..<projects {
            let project = Project(name: "Project \(p)", client: client)
            context.insert(project)
            for t in 0..<(lineCount / projects) {
                let task = TaskType(name: "\(t). Technical implementation", project: project)
                context.insert(task)
                let e = TimeEntry(task: task, date: .now, durationSeconds: 1800,
                                  note: "Changing 3 days to 7 cut off, FAQ update and link to header \(t)")
                context.insert(e)
                entries.append(e)
            }
        }
        return InvoiceBuilder.createInvoice(client: client, bill: entries, cover: [], grouping: .projectTask,
                                            fixedLines: [], settings: settings, context: context)
    }

    @Test func shortInvoiceIsOnePage() {
        let pages = InvoicePDF.pages(for: invoice(lineCount: 3))
        #expect(pages.count == 1)
        #expect(pages[0].showsTotals)
    }

    @Test func longInvoicePaginatesWithTotalsOnLastPageOnly() {
        let inv = invoice(lineCount: 45)
        let pages = InvoicePDF.pages(for: inv)
        #expect(pages.count > 1)
        #expect(pages.dropLast().allSatisfy { !$0.showsTotals })
        #expect(pages.last?.showsTotals == true)
        // Every row appears exactly once.
        let rows = pages.flatMap(\.rows)
        #expect(rows == InvoiceLayout.rows(for: inv.sortedLines))
    }

    @Test func noPageEndsWithAProjectHeading() {
        let pages = InvoicePDF.pages(for: invoice(lineCount: 60, projects: 12))
        for page in pages.dropLast() {
            if case .group = page.rows.last { Issue.record("Page \(page.number) ends with a heading") }
        }
    }

    @Test func writesMultiPagePDF() throws {
        let inv = invoice(lineCount: 45)
        let url = FileManager.default.temporaryDirectory.appending(path: "mytime-test-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try InvoicePDF.write(inv, to: url)
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount == InvoicePDF.pages(for: inv).count)
        let text = doc.string ?? ""
        #expect(text.contains("TAX INVOICE"))
        #expect(text.contains("Amount Due"))
        #expect(text.contains("Page 1 of \(doc.pageCount)"))
    }

    @Test func emailTemplateFilled() {
        let inv = invoice(lineCount: 3)
        let body = InvoiceMailer.fill("Hi {client}, invoice {number} for {total} due {due}. {bank}", invoice: inv)
        #expect(body.contains("Hi Acme, invoice 1 for $"))
        #expect(body.contains("Number: 00-0000"))
        #expect(!body.contains("{"))
    }
}

extension InvoicePDFTests {
    /// Writes a realistic sample to $MYTIME_SAMPLE_PDF for eyeballing the layout.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYTIME_SAMPLE_PDF"] != nil))
    func writeSampleForReview() throws {
        settings.tradingName = "Jane Doe (trading as Example Digital)"
        settings.address = "1 Example Street\nNelson\n7010"
        settings.gstNumber = "123-456-789"
        settings.bankAccount = "Name: Jane Doe\nNumber: 12-3456-7890123-00"
        settings.nextInvoiceNumber = 83
        client.billingName = "Acme"
        let data: [(String, String, [(Double, String)])] = [
            ("AMI Platform // Grab a deal + Hubs", "2. Client workshop", [(1, ""), (0.5, "WIP"), (0.89, "End2End"), (0.58, "AMI WIP"), (0.61, "WIP")]),
            ("AMI Platform // Grab a deal + Hubs", "4. Technical implementation", [(0.75, "Changing 3 days to 7 cut off, FAQ update and AMI link to header"), (0.25, "Text change - Tyres"), (1, "GTM/GA4"), (0.25, "Setting up domain"), (1.75, "Production env set up"), (1, "Shopify confirmation email")]),
            ("AMI Platform // Grab a deal + Hubs", "Team meeting", [(0.12, "Marija WIP")]),
            ("Pharmaco Diabetes Shopify Store", "1. Internal briefing", [(0.62, "Planning meeting")]),
            ("Pharmaco Diabetes Shopify Store", "4. Technical implementation", [(1.5, "Scraper"), (0.5, "Tweaking scraper"), (1.29, "Building Timeline"), (0.25, "Fixing Caresens videos")]),
            ("Team WIP", "Team meeting", [(0.57, "")]),
            ("Women's Health BAU", "4. Technical implementation", [(0.5, "Tracking")]),
            ("Women's Health BAU", "Research", [(0.25, "CMS plan")]),
        ]
        var projects: [String: Project] = [:]
        var entries: [TimeEntry] = []
        for (projectName, taskName, items) in data {
            let project = projects[projectName] ?? Project(name: projectName, client: client)
            if projects[projectName] == nil { context.insert(project); projects[projectName] = project }
            let task = TaskType(name: taskName, project: project)
            context.insert(task)
            for (hours, note) in items {
                let e = TimeEntry(task: task, date: .now, durationSeconds: hours * 3600, note: note)
                context.insert(e)
                entries.append(e)
            }
        }
        let inv = InvoiceBuilder.createInvoice(client: client, bill: entries, cover: [], grouping: .projectTask,
                                               fixedLines: [], settings: settings, context: context)
        let path = ProcessInfo.processInfo.environment["MYTIME_SAMPLE_PDF"]!
        try InvoicePDF.write(inv, to: URL(fileURLWithPath: path))
    }
}
