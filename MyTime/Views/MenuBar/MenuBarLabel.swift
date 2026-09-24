import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let timer: TimerService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The label is the one view that's always alive, so it opens the main window on request.
        content
            .onReceive(NotificationCenter.default.publisher(for: .showMainWindow)) { _ in
                openWindow(id: AppWindows.mainID)
                AppWindows.mainWindowDidAppear()
            }
    }

    @ViewBuilder
    private var content: some View {
        // Menu bar labels only render plain Text/Image, so the pill is drawn as an image,
        // redrawn off the service's 15s tick.
        let now = max(timer.tick, .now)
        if timer.activeEntry != nil {
            Image(nsImage: MenuBarPill.image(DurationFormat.short(timer.elapsed(at: now)), running: true))
        } else if case let total = timer.todayTotal(at: now), total >= 60 {
            Image(nsImage: MenuBarPill.image(DurationFormat.short(total), running: false))
        } else {
            Image(nsImage: ChevronMark.menuBarIcon)
        }
    }
}

/// The Revilo Digital chevrons as monochrome paths, traced from the logo (same outlines as the app icon).
enum ChevronMark {
    private static let back: [CGPoint] = [(48, 37), (111, 37), (199, 120), (131, 191), (213, 274), (182, 307), (68, 191), (136, 120)]
        .map { CGPoint(x: $0.0, y: $0.1) }
    private static let front: [CGPoint] = [(131, 37), (195, 37), (282, 120), (182, 223), (151, 190), (218, 120)]
        .map { CGPoint(x: $0.0, y: $0.1) }

    private static let bounds: CGRect = {
        let all = back + front
        let xs = all.map(\.x), ys = all.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }()

    static func size(height: CGFloat) -> CGSize {
        CGSize(width: bounds.width * height / bounds.height, height: height)
    }

    /// Both chevrons fitted to `height` with their bottom-left at `origin` (AppKit coordinates, y up).
    static func paths(height: CGFloat, origin: CGPoint) -> (back: NSBezierPath, front: NSBezierPath) {
        let scale = height / bounds.height
        func path(_ points: [CGPoint]) -> NSBezierPath {
            let path = NSBezierPath()
            for (index, p) in points.enumerated() {
                let point = CGPoint(x: origin.x + (p.x - bounds.minX) * scale, y: origin.y + (bounds.maxY - p.y) * scale)
                index == 0 ? path.move(to: point) : path.line(to: point)
            }
            path.close()
            path.lineJoinStyle = .miter
            return path
        }
        return (path(back), path(front))
    }

    /// Idle menu bar icon: solid back chevron, lighter front chevron separated by a hairline gap.
    static let menuBarIcon: NSImage = {
        let height: CGFloat = 15
        let mark = size(height: height)
        let canvas = NSSize(width: ceil(mark.width) + 2, height: 18)
        let image = NSImage(size: canvas, flipped: false) { _ in
            let (back, front) = paths(height: height, origin: CGPoint(x: 1, y: (canvas.height - height) / 2))
            NSColor.black.setFill()
            back.fill()
            // Cut a gap where the front chevron overlaps, then draw it lighter.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            front.lineWidth = 2.2
            NSColor.black.setStroke()
            front.stroke()
            front.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.withAlphaComponent(0.6).setFill()
            front.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MyTime"
        return image
    }()
}

/// Running: a filled pill with the chevrons and time knocked out, like the battery percentage.
/// Stopped: an outlined pill with today's total. Template images, so macOS tints them.
enum MenuBarPill {
    static func image(_ text: String, running: Bool = true) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let markHeight: CGFloat = 11
        let markSize = ChevronMark.size(height: markHeight)

        let height: CGFloat = 18
        let gap: CGFloat = 5
        let padding: CGFloat = 7
        let width = ceil(padding + markSize.width + gap + textSize.width + padding)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return true }
            let (back, front) = ChevronMark.paths(height: markHeight, origin: CGPoint(x: padding, y: (height - markHeight) / 2))
            let textOrigin = NSPoint(x: padding + markSize.width + gap, y: (height - textSize.height) / 2 + 0.5)
            NSColor.black.setFill()
            NSColor.black.setStroke()

            if running {
                NSBezierPath(roundedRect: rect, xRadius: 5.5, yRadius: 5.5).fill()
                // Knock out the back chevron fully, restore a hairline gap, then knock out the front one partly.
                context.compositingOperation = .destinationOut
                back.fill()
                context.compositingOperation = .sourceOver
                front.lineWidth = 2
                front.stroke()
                context.compositingOperation = .destinationOut
                NSColor.black.withAlphaComponent(0.7).setFill()
                front.fill()
                NSColor.black.setFill()
                (text as NSString).draw(at: textOrigin, withAttributes: attributes)
            } else {
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
                outline.lineWidth = 1.5
                outline.stroke()
                back.fill()
                context.compositingOperation = .destinationOut
                front.lineWidth = 1.6
                front.stroke()
                front.fill()
                context.compositingOperation = .sourceOver
                NSColor.black.withAlphaComponent(0.6).setFill()
                front.fill()
                (text as NSString).draw(at: textOrigin, withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = running ? "Timer running, \(text)" : "Stopped, \(text) today"
        return image
    }
}
