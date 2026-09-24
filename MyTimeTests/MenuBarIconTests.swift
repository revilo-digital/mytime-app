import AppKit
import Testing
@testable import MyTime

@MainActor
struct MenuBarIconTests {
    @Test func iconsAreTemplatesSizedForTheMenuBar() {
        #expect(ChevronMark.menuBarIcon.isTemplate)
        #expect(ChevronMark.menuBarIcon.size.height == 18)
        let pill = MenuBarPill.image("1:42")
        #expect(pill.isTemplate)
        #expect(pill.size.height == 18)
    }

    /// Set MYTIME_ICON_PREVIEW=/path/to/file.png to render the icons on light and dark bars at 4x.
    @Test func writePreviewIfRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["MYTIME_ICON_PREVIEW"] else { return }
        let icons = [ChevronMark.menuBarIcon, MenuBarPill.image("1:42", running: false), MenuBarPill.image("0:12")]
        let scale: CGFloat = 4
        let width = (icons.map(\.size.width).reduce(0, +) + 30) * scale
        let rowHeight: CGFloat = 26 * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(rowHeight * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, (background, tint)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black),
                                         (NSColor(white: 0.15, alpha: 1), NSColor.white)].enumerated() {
            let y = CGFloat(1 - row) * rowHeight
            background.setFill()
            NSRect(x: 0, y: y, width: width, height: rowHeight).fill()
            var x: CGFloat = 10 * scale
            for icon in icons {
                let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
                let tinted = NSImage(size: icon.size, flipped: false) { rect in
                    icon.draw(in: rect)
                    tint.set()
                    rect.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: NSRect(x: x, y: y + (rowHeight - size.height) / 2, width: size.width, height: size.height))
                x += size.width + 10 * scale
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: path))
    }
}
