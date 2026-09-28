// Draws the Star Traders Sync app icon and writes AppIcon.icns.
//
//   swift macos/icon/make-icon.swift <outdir>
//
// Everything is drawn from code, so the icon is reviewed as a diff and
// rebuilt on every build; there is no design file to keep in sync.
// Writes <outdir>/AppIcon.iconset (every size macOS asks for),
// <outdir>/AppIcon.icns and <outdir>/AppIcon-1024.png as a preview.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift make-icon.swift <outdir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// One icon at `px` pixels square. Everything is laid out on a 1024 grid
/// and scaled, so all sizes share the exact geometry.
func render(_ px: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high

    // macOS Big Sur grid: an 824pt rounded square centred on 1024, which
    // leaves the ~10% margin the system shadow and other icons expect.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(16, 20, 48))
    ctx.fillPath()
    ctx.restoreGState()

    // Deep space: navy at the bottom to indigo at the top.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: cs,
                        colors: [rgb(12, 16, 42), rgb(46, 36, 112)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // A faint glow behind the letters so they sit in light, not on flat colour.
    let glow = CGGradient(colorsSpace: cs,
                          colors: [rgb(120, 110, 255, 0.28), rgb(120, 110, 255, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 500), endRadius: 420, options: [])

    // A few distant stars. Small and dim on purpose: at 16px they vanish
    // and leave only the monogram, which is what should survive.
    for (x, y, r, a) in [(250.0, 790.0, 7.0, 0.55), (770.0, 250.0, 5.0, 0.4), (320.0, 230.0, 4.0, 0.35),
                         (690.0, 820.0, 4.5, 0.4)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        ctx.setFillColor(rgb(220, 225, 255, a))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    ctx.restoreGState()

    // One bright four-point star, top right: the "Star" in Star Traders.
    func sparkle(_ c: CGPoint, _ r: CGFloat) {
        let p = CGMutablePath()
        let w = r * 0.22
        p.move(to: CGPoint(x: c.x, y: c.y + r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y + w))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + w, y: c.y - w))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y - w))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - w, y: c.y + w))
        ctx.addPath(p)
        ctx.setFillColor(rgb(255, 236, 170))
        ctx.fillPath()
    }
    sparkle(CGPoint(x: 778, y: 790), 64)

    // The monogram. Heavy, rounded, slightly tight so "ST" reads as one
    // mark; white with a light shadow so it holds at 16px.
    let font = NSFont.systemFont(ofSize: 440, weight: .heavy)
    let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 440) } ?? font
    let text = NSAttributedString(string: "ST", attributes: [
        .font: rounded,
        .foregroundColor: NSColor.white,
        .kern: -16,
    ])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0, 0, 20, 0.55))
    ctx.textPosition = CGPoint(x: 512 - bounds.midX, y: 480 - bounds.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: url)
}

// Every size iconutil expects in an .iconset.
for base in [16, 32, 128, 256, 512] {
    try writePNG(render(base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(render(base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try writePNG(render(1024), to: outDir.appendingPathComponent("AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed with \(iconutil.terminationStatus)\n".data(using: .utf8)!)
    exit(1)
}
print(outDir.appendingPathComponent("AppIcon.icns").path)
