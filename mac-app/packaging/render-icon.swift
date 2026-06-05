import AppKit
import Foundation

// Renders the zyncir app-icon master PNG: the clipboard glyph (same motif as the
// menu-bar icon) in white on a blue gradient squircle tile.
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

// Squircle-ish rounded background with a top-to-bottom blue gradient.
let rect = CGRect(x: 0, y: 0, width: S, height: S)
let radius = S * 0.2235
cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
cg.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(srgbRed: 0.33, green: 0.68, blue: 1.00, alpha: 1).cgColor,
             NSColor(srgbRed: 0.09, green: 0.35, blue: 0.86, alpha: 1).cgColor] as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

// Clipboard glyph, white, centered.
let cfg = NSImage.SymbolConfiguration(pointSize: S * 0.46, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
    let gs = sym.size
    sym.draw(in: CGRect(x: (S - gs.width) / 2, y: (S - gs.height) / 2, width: gs.width, height: gs.height))
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
