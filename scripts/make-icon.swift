// Renders Lintel's app icon: a soft light squircle with the notch growing two wings —
// coloured session dots on the left, equaliser bars on the right.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle with a gentle top-to-bottom grade and a soft drop shadow.
    let inset = s * 0.1
    let r = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: r, xRadius: r.width * 0.23, yRadius: r.width * 0.23)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [rgb(0xFFFFFF), rgb(0xE9E9EE)])!.draw(in: squircle, angle: -90)
    NSColor(white: 0, alpha: 0.08).setStroke()
    squircle.lineWidth = s * 0.004
    squircle.stroke()

    // The notch: flush with the top edge, rounded below, extended into wings.
    let barH = r.height * 0.2
    let bar = NSRect(x: r.minX + r.width * 0.12, y: r.maxY - barH - r.height * 0.0, width: r.width * 0.76, height: barH)
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let notch = NSBezierPath(roundedRect: bar.insetBy(dx: 0, dy: -barH * 0.5).offsetBy(dx: 0, dy: barH * 0.5),
                             xRadius: barH * 0.55, yRadius: barH * 0.55)
    NSColor(white: 0.04, alpha: 1).setFill()
    notch.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Left wing: three overlapping session dots.
    let d = barH * 0.5
    let colors = [rgb(0x3B82F6), rgb(0x8B5CF6), rgb(0x10A37F)]
    for (i, c) in colors.enumerated() {
        let x = bar.minX + barH * 0.55 + CGFloat(i) * d * 0.72
        let dot = NSBezierPath(ovalIn: NSRect(x: x, y: bar.midY - d / 2, width: d, height: d))
        c.setFill()
        dot.fill()
        NSColor(white: 0.04, alpha: 1).setStroke()
        dot.lineWidth = d * 0.12
        dot.stroke()
    }
    // Right wing: equaliser bars.
    let heights: [CGFloat] = [0.35, 0.65, 0.45, 0.8]
    let bw = barH * 0.1
    for (i, h) in heights.enumerated() {
        let x = bar.maxX - barH * 0.6 - CGFloat(3 - i) * bw * 1.9
        let hh = barH * 0.5 * h
        NSColor(white: 1, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: bar.midY - barH * 0.25, width: bw, height: hh), xRadius: bw / 2, yRadius: bw / 2).fill()
    }

    // A card hanging below, like the notch dropping open.
    let card = NSRect(x: r.minX + r.width * 0.22, y: r.minY + r.height * 0.17, width: r.width * 0.56, height: r.height * 0.44)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: card.width * 0.12, yRadius: card.width * 0.12)
    let cs = NSShadow()
    cs.shadowColor = NSColor(white: 0, alpha: 0.18)
    cs.shadowBlurRadius = s * 0.03
    cs.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    cs.set()
    NSColor.white.setFill()
    cardPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 0, alpha: 0.06).setStroke()
    cardPath.lineWidth = s * 0.003
    cardPath.stroke()
    // Two rows: a coloured avatar + text lines.
    for (i, c) in [rgb(0x3B82F6), rgb(0xF97316)].enumerated() {
        let rowY = card.maxY - card.height * (0.33 + CGFloat(i) * 0.36)
        let a = card.height * 0.2
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: card.minX + card.width * 0.1, y: rowY - a / 2, width: a, height: a)).fill()
        NSColor(white: 0.1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: card.minX + card.width * 0.32, y: rowY + a * 0.08, width: card.width * 0.5, height: a * 0.26),
                     xRadius: a * 0.13, yRadius: a * 0.13).fill()
        NSColor(white: 0.1, alpha: 0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: card.minX + card.width * 0.32, y: rowY - a * 0.36, width: card.width * 0.34, height: a * 0.22),
                     xRadius: a * 0.11, yRadius: a * 0.11).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
