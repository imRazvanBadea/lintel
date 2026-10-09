// Crops a transparent panel snapshot around the bar and card and puts it on a screen-like backdrop.
// usage: swift scripts/compose-shot.swift <in.png> <out.png> <x> <y> <w> <h> <dark|light>   (rect in points)
import AppKit

let a = CommandLine.arguments
guard a.count == 8, let src = NSImage(contentsOfFile: a[1]),
      let x = Double(a[3]), let y = Double(a[4]), let w = Double(a[5]), let h = Double(a[6]) else {
    FileHandle.standardError.write("usage: compose-shot <in> <out> x y w h dark|light\n".data(using: .utf8)!)
    exit(1)
}
let dark = a[7] == "dark"
guard let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let scale = Double(cg.width) / src.size.width
// Snapshot coordinates have a top-left origin, like SwiftUI.
let crop = CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale).integral
guard let piece = cg.cropping(to: crop) else { exit(1) }

let size = NSSize(width: crop.width, height: crop.height)
let out = NSImage(size: size, flipped: false) { r in
    // Desktop-like gradient with a menu bar band at the top.
    let colors = dark ? [NSColor(srgbRed: 0.16, green: 0.15, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.07, green: 0.08, blue: 0.13, alpha: 1)]
                      : [NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.85, green: 0.87, blue: 0.91, alpha: 1)]
    NSGradient(colors: colors)!.draw(in: r, angle: -90)
    let bar = 32 * scale
    (dark ? NSColor(white: 0.08, alpha: 0.85) : NSColor(white: 1, alpha: 0.6)).setFill()
    NSRect(x: 0, y: r.height - bar, width: r.width, height: bar).fill()
    NSGraphicsContext.current?.cgContext.draw(piece, in: r)
    return true
}
guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: a[2]))
