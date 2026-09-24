import AppKit
import Testing
@testable import MyTime

struct ClientLogoTests {
    @Test func downscalesWideImageToSquarePNG() throws {
        let wide = NSImage(size: NSSize(width: 1200, height: 300), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(wide.tiffRepresentation)
        let data = try #require(ClientLogo.thumbnail(from: tiff))
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide == 256)
        #expect(rep.pixelsHigh == 256)
    }

    @Test func rejectsNonImageData() {
        #expect(ClientLogo.thumbnail(from: Data("not an image".utf8)) == nil)
    }
}
