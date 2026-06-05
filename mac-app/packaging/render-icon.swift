import AppKit
import Foundation

// Renders the zyncir app-icon master PNG in a modern macOS style: a rounded
// squircle tile with a neutral light→dark gray gradient, soft drop shadow and a
// top sheen for depth, and the clipboard glyph (same motif as the menu-bar icon)
// rendered in two-tone slate via SF Symbols hierarchical rendering.
// Usage: swift render-icon.swift <out.png>

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon_1024.png"
let S: CGFloat = 1024

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("could not create bitmap context")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
cg.interpolationQuality = .high

// Tile inset so the soft shadow has room — the standard macOS look.
let margin = S * 0.085
let tile = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = tile.width * 0.2237
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft drop shadow beneath the tile.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.05,
             color: NSColor(white: 0, alpha: 0.28).cgColor)
cg.addPath(tilePath); cg.setFillColor(NSColor.white.cgColor); cg.fillPath()
cg.restoreGState()

// Neutral gray gradient: light at top, darker at bottom (slight cool cast).
cg.saveGState()
cg.addPath(tilePath); cg.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(srgbRed: 0.945, green: 0.950, blue: 0.960, alpha: 1).cgColor,
             NSColor(srgbRed: 0.690, green: 0.705, blue: 0.730, alpha: 1).cgColor] as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Subtle top sheen.
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(white: 1, alpha: 0.35).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(sheen, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
cg.restoreGState()

// Hairline inner highlight for crisp edge definition.
cg.saveGState()
cg.addPath(tilePath)
cg.setStrokeColor(NSColor(white: 1, alpha: 0.5).cgColor)
cg.setLineWidth(S * 0.004)
cg.strokePath()
cg.restoreGState()

// Clipboard glyph — two-tone slate, centered, with a faint shadow for depth.
let cfg = NSImage.SymbolConfiguration(pointSize: tile.width * 0.50, weight: .regular)
    .applying(NSImage.SymbolConfiguration(hierarchicalColor: NSColor(srgbRed: 0.24, green: 0.27, blue: 0.31, alpha: 1)))
if let sym = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
    let gs = sym.size
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -S * 0.004), blur: S * 0.012,
                 color: NSColor(white: 0, alpha: 0.18).cgColor)
    sym.draw(in: CGRect(x: tile.midX - gs.width / 2, y: tile.midY - gs.height / 2, width: gs.width, height: gs.height))
    cg.restoreGState()
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
