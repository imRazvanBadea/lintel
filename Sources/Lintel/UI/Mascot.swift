import SwiftUI
import AppKit
import QuartzCore

/// The little blob that stands in for each agent session.
struct Mascot: View {
    enum Mood { case working, happy, worried, sleeping, idle }
    var color: Color
    var mood: Mood
    var size: CGFloat = 20

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let bodyRect = CGRect(x: 0, y: h * 0.06, width: w, height: h * 0.88)
            let fill = mood == .sleeping ? Color(white: 0.30) : color
            ctx.fill(Path(roundedRect: bodyRect, cornerRadius: h * 0.42, style: .continuous), with: .color(fill))

            let ink = mood == .sleeping ? Color.white.opacity(0.85) : Color.black.opacity(0.82)
            let ey = h * 0.44, lx = w * 0.36, rx = w * 0.62, r = h * 0.085
            let stroke = StrokeStyle(lineWidth: max(1.2, h * 0.08), lineCap: .round)

            func dot(_ x: CGFloat, _ y: CGFloat, _ rr: CGFloat) {
                ctx.fill(Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2)), with: .color(ink))
            }
            func arc(_ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat, up: Bool) {
                var p = Path()
                p.addArc(center: CGPoint(x: cx, y: cy), radius: rad,
                         startAngle: .degrees(up ? 200 : 20), endAngle: .degrees(up ? 340 : 160), clockwise: false)
                ctx.stroke(p, with: .color(ink), style: stroke)
            }

            switch mood {
            case .happy:
                arc(lx, ey + h * 0.05, h * 0.09, up: true)
                arc(rx, ey + h * 0.05, h * 0.09, up: true)
                arc(w * 0.49, h * 0.56, h * 0.13, up: false)
            case .working:
                dot(lx, ey, r)
                dot(rx, ey, r)
                var p = Path()
                p.addArc(center: CGPoint(x: w * 0.53, y: h * 0.58), radius: h * 0.1,
                         startAngle: .degrees(20), endAngle: .degrees(120), clockwise: false)
                ctx.stroke(p, with: .color(ink), style: stroke)
            case .worried:
                dot(lx, ey - h * 0.02, r * 1.15)
                dot(rx, ey - h * 0.02, r * 1.15)
                var p = Path()
                p.move(to: CGPoint(x: w * 0.44, y: h * 0.7))
                p.addLine(to: CGPoint(x: w * 0.54, y: h * 0.7))
                ctx.stroke(p, with: .color(ink), style: stroke)
            case .sleeping:
                arc(lx, ey - h * 0.02, h * 0.08, up: false)
                arc(rx, ey - h * 0.02, h * 0.08, up: false)
                let z = Text("z").font(.system(size: h * 0.42, weight: .heavy, design: .rounded)).foregroundColor(.white)
                ctx.draw(z, at: CGPoint(x: w * 0.86, y: h * 0.26))
            case .idle:
                dot(lx, ey, r)
                dot(rx, ey, r)
                var p = Path()
                p.move(to: CGPoint(x: w * 0.44, y: h * 0.66))
                p.addLine(to: CGPoint(x: w * 0.56, y: h * 0.66))
                ctx.stroke(p, with: .color(ink), style: stroke)
            }
        }
        .frame(width: size * 1.45, height: size)
    }
}

extension AgentSession {
    var mood: Mascot.Mood {
        switch status {
        case .waiting: .worried
        case .working: .working
        case .finished: .happy
        case .idle: .sleeping
        }
    }
    var tint: Color { Theme.color(colorIndex) }
    var statusColor: Color {
        switch status {
        case .waiting: Theme.amber
        case .working: tint
        case .finished: Theme.green
        case .idle: Color(white: 0.45)
        }
    }
}

// MARK: - Core Animation-backed indicators (animate in the render server, ~0% app CPU)

/// A spinning arc.
struct RingSpinner: NSViewRepresentable {
    var color: NSColor
    var lineWidth: CGFloat = 2.5
    var spinning = true
    var progress: CGFloat = 0.28   // arc length when spinning, ring fill otherwise

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let track = CAShapeLayer()
        track.name = "track"
        let arc = CAShapeLayer()
        arc.name = "arc"
        v.layer?.addSublayer(track)
        v.layer?.addSublayer(arc)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let layer = v.layer, let subs = layer.sublayers, subs.count == 2,
              let track = subs[0] as? CAShapeLayer, let arc = subs[1] as? CAShapeLayer else { return }
        let b = v.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = CGPath(ellipseIn: b, transform: nil)
        for l in [track, arc] {
            l.frame = v.bounds
            l.path = path
            l.fillColor = nil
            l.lineWidth = lineWidth
            l.lineCap = .round
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        arc.strokeColor = color.cgColor
        arc.strokeEnd = progress
        if spinning {
            if arc.animation(forKey: "spin") == nil {
                let a = CABasicAnimation(keyPath: "transform.rotation.z")
                a.fromValue = 0
                a.toValue = -2 * CGFloat.pi
                a.duration = 1.1
                a.repeatCount = .infinity
                a.isRemovedOnCompletion = false
                arc.add(a, forKey: "spin")
            }
        } else {
            arc.removeAnimation(forKey: "spin")
        }
    }
}

/// Little equaliser bars that bounce while music plays.
struct Equalizer: NSViewRepresentable {
    var color: NSColor
    var playing: Bool
    var bars = 4

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        for _ in 0..<bars {
            let l = CALayer()
            l.anchorPoint = CGPoint(x: 0.5, y: 0)
            v.layer?.addSublayer(l)
        }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let layers = v.layer?.sublayers else { return }
        let b = v.bounds
        let gap: CGFloat = 2
        let w = (b.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
        let durations: [Double] = [0.42, 0.55, 0.36, 0.48, 0.6]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in layers.enumerated() {
            l.backgroundColor = color.cgColor
            l.cornerRadius = w / 2
            l.bounds = CGRect(x: 0, y: 0, width: w, height: b.height)
            l.position = CGPoint(x: CGFloat(i) * (w + gap) + w / 2, y: 0)
            if playing {
                if l.animation(forKey: "eq") == nil {
                    let a = CABasicAnimation(keyPath: "transform.scale.y")
                    a.fromValue = 0.18
                    a.toValue = 1.0
                    a.duration = durations[i % durations.count]
                    a.autoreverses = true
                    a.repeatCount = .infinity
                    a.timeOffset = Double(i) * 0.17
                    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    a.isRemovedOnCompletion = false
                    l.add(a, forKey: "eq")
                }
            } else {
                l.removeAnimation(forKey: "eq")
                l.transform = CATransform3DMakeScale(1, 0.2, 1)
            }
        }
        CATransaction.commit()
    }
}
