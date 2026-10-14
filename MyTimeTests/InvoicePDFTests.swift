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

    @Test func noPageEndsWithAHeading() {
        let pages = InvoicePDF.pages(for: invoice(lineCount: 60, projects: 12))
        for page in pages.dropLast() where page.rows.last?.isHeading == true {
            Issue.record("Page \(page.number) ends with a heading")
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
        let globex = EndClient(name: "Globex", client: client)
        let initech = EndClient(name: "Initech", client: client)
        context.insert(globex)
        context.insert(initech)
        let data: [(EndClient?, String, String, [(Double, String)])] = [
            (globex, "Spring Campaign", "2. Client workshop", [(1, ""), (0.5, "WIP"), (0.89, "End-to-end review"), (0.58, "Campaign WIP"), (0.61, "WIP")]),
            (globex, "Spring Campaign", "4. Technical implementation", [(0.75, "Changing 3 days to 7 day cut-off, FAQ update and link in header"), (0.25, "Copy changes"), (1, "GTM/GA4"), (0.25, "Setting up domain"), (1.75, "Production environment set up"), (1, "Confirmation email")]),
            (globex, "Spring Campaign", "Team meeting", [(0.12, "WIP")]),
            (initech, "Online Store", "1. Internal briefing", [(0.62, "Planning meeting")]),
            (initech, "Online Store", "4. Technical implementation", [(1.5, "Product importer"), (0.5, "Tweaking importer"), (1.29, "Building timeline"), (0.25, "Fixing product videos")]),
            (initech, "Support Retainer", "4. Technical implementation", [(0.5, "Tracking")]),
            (initech, "Support Retainer", "Research", [(0.25, "CMS plan")]),
            (nil, "Team WIP", "Team meeting", [(0.57, "")]),
        ]
        var projects: [String: Project] = [:]
        var entries: [TimeEntry] = []
        for (endClient, projectName, taskName, items) in data {
            let project = projects[projectName] ?? Project(name: projectName, client: client)
            project.endClient = endClient
            if projects[projectName] == nil { context.insert(project); projects[projectName] = project }
            let task = TaskType(name: taskName, project: project)
            context.insert(task)
            for (hours, note) in items {
                let e = TimeEntry(task: task, date: .now, durationSeconds: hours * 3600, note: note)
                context.insert(e)
                entries.append(e)
            }
        }
        let rescue = Project(name: "Loyalty App", client: client, billingType: .fixedFee)
        rescue.endClient = globex
        context.insert(rescue)
        let inv = InvoiceBuilder.createInvoice(client: client, bill: entries, cover: [], grouping: .projectTask, bySection: true,
                                               fixedLines: [FixedLineInput(description: "Loyalty App - agreed fee", amount: 5000, project: rescue)],
                                               settings: settings, context: context)
        let path = ProcessInfo.processInfo.environment["MYTIME_SAMPLE_PDF"]!
        try InvoicePDF.write(inv, to: URL(fileURLWithPath: path))
    }
}
