import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The client's avatar in the detail header: click to choose a logo, or drop an image on it.
struct LogoPicker: View {
    @Bindable var client: Client
    var size: CGFloat = 56

    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        Menu {
            Button(client.logoData == nil ? "Choose Logo…" : "Change Logo…") { Self.choose(for: client) }
            Button("Paste Image") { Self.paste(into: client) }
                .disabled(!NSPasteboard.general.canReadObject(forClasses: [NSImage.self]))
            if client.logoData != nil {
                Divider()
                Button("Remove Logo", role: .destructive) { client.logoData = nil }
            }
        } label: {
            Avatar(name: client.name, size: size, imageData: client.logoData)
                .overlay {
                    if hovering || targeted {
                        Circle().fill(.black.opacity(0.45))
                        Image(systemName: targeted ? "arrow.down.circle" : "camera").foregroundStyle(.white).font(.title3)
                    }
                }
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: targeted ? 3 : 0))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Set a logo for \(client.name)")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, let data = try? Data(contentsOf: url), let logo = ClientLogo.thumbnail(from: data) else { return false }
            client.logoData = logo
            return true
        } isTargeted: { targeted = $0 }
    }

    static func choose(for client: Client) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .pdf, .svg, .webP, .gif, .icns]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo for \(client.name)"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        client.logoData = ClientLogo.thumbnail(from: data)
    }

    static func paste(into client: Client) {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
              let tiff = image.tiffRepresentation else { return }
        client.logoData = ClientLogo.thumbnail(from: tiff)
    }
}

enum ClientLogo {
    /// Downscales any image to fit a 256px square PNG (transparent padding keeps wide logos intact).
    static func thumbnail(from data: Data, side: CGFloat = 256) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(side / image.size.width, side / image.size.height)
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
