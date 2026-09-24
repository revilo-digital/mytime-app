// Draws the MyTime app icon (Revilo Digital chevrons) at 1024×1024.
// Run: swift scripts/make-icon.swift out.png [light|dark]
import AppKit

let size: CGFloat = 1024
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "dark"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1).cgColor
}
let brandDark = srgb(0, 68, 85)      // #004455
let brandLight = srgb(0, 120, 149)   // #007895

// macOS icon grid: 824pt rounded square centred on the canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let background: [CGColor] = variant == "dark"
    ? [srgb(0, 88, 108), srgb(0, 44, 56)]
    : [srgb(255, 255, 255), srgb(226, 236, 239)]
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: background as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Chevron outlines traced from the Revilo Digital logo (source pixels, y down).
let darkShape: [CGPoint] = [(48, 37), (111, 37), (199, 120), (131, 191), (213, 274), (182, 307), (68, 191), (136, 120)].map { CGPoint(x: $0.0, y: $0.1) }
let lightShape: [CGPoint] = [(131, 37), (195, 37), (282, 120), (182, 223), (151, 190), (218, 120)].map { CGPoint(x: $0.0, y: $0.1) }

// Fit the logo's bounding box into the tile, centred, flipping y.
let all = darkShape + lightShape
let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
let minY = all.map(\.y).min()!, maxY = all.map(\.y).max()!
let scale: CGFloat = 540 / (maxY - minY)
let offsetX = 512 - (minX + maxX) / 2 * scale
let offsetY = 512 + (minY + maxY) / 2 * scale
func place(_ p: CGPoint) -> CGPoint { CGPoint(x: offsetX + p.x * scale, y: offsetY - p.y * scale) }

func fill(_ shape: [CGPoint], _ color: CGColor) {
    ctx.beginPath()
    ctx.addLines(between: shape.map(place))
    ctx.closePath()
    ctx.setFillColor(color)
    ctx.fillPath()
}

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(variant == "dark" ? 0.35 : 0.12).cgColor)
if variant == "dark" {
    fill(darkShape, srgb(255, 255, 255))
    fill(lightShape, srgb(92, 196, 218))
} else {
    fill(darkShape, brandDark)
    fill(lightShape, brandLight)
}
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
