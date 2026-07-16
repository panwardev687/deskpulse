// make_icon.swift - generates AppIcon.icns for DeskPulse.
// Same family look as MacPulse: deep navy gradient squircle with faint grid
// lines, one glowing mark. Here the mark is a cyan clipboard with a small
// pulse line across it.
// Run: swift scripts/make_icon.swift   (from the project root)

import AppKit

let canvas: CGFloat = 1024
let accent = NSColor(srgbRed: 0.24, green: 0.78, blue: 1.0, alpha: 1)      // #3DC7FF
let accentCore = NSColor(srgbRed: 0.82, green: 0.95, blue: 1.0, alpha: 1)  // near white

func drawIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: canvas, height: canvas))
    img.lockFocus()

    // - squircle plate on Apple's icon grid
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()

    // background: deep navy vertical gradient
    NSGradient(colors: [
        NSColor(srgbRed: 0.055, green: 0.098, blue: 0.184, alpha: 1),  // #0E1930 bottom
        NSColor(srgbRed: 0.129, green: 0.227, blue: 0.396, alpha: 1),  // #213A65 top
    ])?.draw(in: plate, angle: 90)

    // faint horizontal grid lines - the family "instrument" feel
    NSColor.white.withAlphaComponent(0.045).setStroke()
    for i in 1..<8 {
        let y = plate.minY + plate.height * CGFloat(i) / 8
        let line = NSBezierPath()
        line.move(to: NSPoint(x: plate.minX, y: y))
        line.line(to: NSPoint(x: plate.maxX, y: y))
        line.lineWidth = 3
        line.stroke()
    }

    // - the mark: clipboard outline + pulse line across it
    let board = NSRect(x: 342, y: 236, width: 340, height: 480)
    let mark = NSBezierPath(roundedRect: board, xRadius: 46, yRadius: 46)
    // clip tab at the top
    let tab = NSBezierPath(
        roundedRect: NSRect(x: board.midX - 74, y: board.maxY - 26, width: 148, height: 66),
        xRadius: 24, yRadius: 24)
    mark.append(tab)

    // pulse line running through the clipboard, wider than it
    let baseline = board.midY - 30
    let pulse = NSBezierPath()
    pulse.move(to: NSPoint(x: 220, y: baseline))
    pulse.line(to: NSPoint(x: 400, y: baseline))
    pulse.line(to: NSPoint(x: 452, y: baseline + 116))  // spike up
    pulse.line(to: NSPoint(x: 512, y: baseline - 96))   // drop below
    pulse.line(to: NSPoint(x: 560, y: baseline))
    pulse.line(to: NSPoint(x: 804, y: baseline))

    for path in [mark, pulse] {
        path.lineWidth = 34
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
    }

    // glow pass
    let glow = NSShadow()
    glow.shadowColor = accent.withAlphaComponent(0.9)
    glow.shadowBlurRadius = 44
    glow.shadowOffset = .zero
    NSGraphicsContext.current?.saveGraphicsState()
    glow.set()
    accent.setStroke()
    mark.stroke()
    pulse.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()

    // bright core pass
    for path in [mark, pulse] {
        let core = path.copy() as! NSBezierPath
        core.lineWidth = 15
        accentCore.setStroke()
        core.stroke()
    }

    // subtle top sheen
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.10),
        NSColor.white.withAlphaComponent(0.0),
    ])?.draw(in: NSRect(x: plate.minX, y: plate.midY + 130,
                        width: plate.width, height: plate.height / 2 - 130),
             angle: 90)

    NSGraphicsContext.current?.restoreGraphicsState()

    // hairline edge so the plate reads on white backgrounds
    NSColor.white.withAlphaComponent(0.08).setStroke()
    squircle.lineWidth = 4
    squircle.stroke()

    img.unlockFocus()
    return img
}

func pngData(_ base: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    base.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
              from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let icon = drawIcon()
let fm = FileManager.default
let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in entries {
    try! pngData(icon, pixels: px).write(to: iconset.appendingPathComponent(name))
}
print("iconset written - now run: iconutil -c icns AppIcon.iconset")
