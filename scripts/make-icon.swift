// Renders Lintel's app icon: a dark squircle with a glowing lintel bar and a little blob.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let r = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: r, xRadius: r.width * 0.23, yRadius: r.width * 0.23)
    NSGradient(colors: [NSColor(white: 0.24, alpha: 1), NSColor(white: 0.02, alpha: 1)])!.draw(in: squircle, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke(); squircle.lineWidth = s * 0.006; squircle.stroke()

    // The lintel: a pill across the top.
    let bar = NSRect(x: r.minX + r.width * 0.2, y: r.maxY - r.height * 0.27, width: r.width * 0.6, height: r.height * 0.11)
    NSColor.black.setFill(); NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
    NSColor(white: 1, alpha: 0.12).setStroke()
    let barPath = NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2); barPath.lineWidth = s * 0.004; barPath.stroke()
    // Dots in the pill (sessions).
    let colors: [NSColor] = [NSColor(red: 0.49, green: 0.72, blue: 1, alpha: 1), NSColor(red: 0.55, green: 0.49, blue: 1, alpha: 1), NSColor(red: 0.37, green: 0.83, blue: 0.6, alpha: 1)]
    for (i, c) in colors.enumerated() {
        let d = bar.height * 0.34
        let x = bar.minX + bar.height * 0.6 + CGFloat(i) * d * 1.8
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: bar.midY - d / 2, width: d, height: d)).fill()
    }

    // The blob.
    let bw = r.width * 0.5, bh = bw / 1.45
    let blob = NSRect(x: r.midX - bw / 2, y: r.minY + r.height * 0.2, width: bw, height: bh)
    NSColor(red: 0.49, green: 0.72, blue: 1, alpha: 1).setFill()
    NSBezierPath(roundedRect: blob, xRadius: bh * 0.45, yRadius: bh * 0.45).fill()
    NSColor(white: 0, alpha: 0.85).setStroke()
    for ex in [0.36, 0.62] {
        let p = NSBezierPath()
        p.appendArc(withCenter: NSPoint(x: blob.minX + bw * ex, y: blob.minY + bh * 0.52), radius: bh * 0.09, startAngle: 20, endAngle: 160)
        p.lineWidth = bh * 0.08; p.lineCapStyle = .round; p.stroke()
    }
    let m = NSBezierPath()
    m.appendArc(withCenter: NSPoint(x: blob.midX, y: blob.minY + bh * 0.42), radius: bh * 0.13, startAngle: 200, endAngle: 340)
    m.lineWidth = bh * 0.08; m.lineCapStyle = .round; m.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
