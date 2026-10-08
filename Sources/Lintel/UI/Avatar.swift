import SwiftUI
import AppKit
import QuartzCore

/// A session's badge: a coloured circle with the first letter of its project,
/// ringed by a spinner while it works.
struct Avatar: View {
    let session: AgentSession
    var size: CGFloat = 28
    var showsActivity = true

    var body: some View {
        ZStack {
            Circle().fill(session.tint)
            Text(session.initial)
                .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if showsActivity {
                switch session.status {
                case .working:
                    RingSpinner(color: NSColor(session.tint), lineWidth: max(1.5, size * 0.07))
                        .frame(width: size + size * 0.36, height: size + size * 0.36)
                case .waiting:
                    Circle().strokeBorder(Theme.amber, lineWidth: max(1.5, size * 0.07))
                        .frame(width: size + size * 0.36, height: size + size * 0.36)
                default:
                    EmptyView()
                }
            }
        }
        .frame(width: size, height: size)
        .opacity(session.status == .idle ? 0.55 : 1)
    }
}

extension AgentSession {
    /// First letter of the project folder (falls back to the agent's name).
    var initial: String {
        let name = project.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return String((name.first ?? kind.label.first ?? "?")).uppercased()
    }
    var tint: Color { Theme.color(colorIndex) }
    var statusColor: Color {
        switch status {
        case .waiting: Theme.amber
        case .working: tint
        case .finished: Theme.green
        case .idle: Color(white: 0.75)
        }
    }
}

// MARK: - Core Animation-backed indicators (animate in the render server, ~0% app CPU)

/// A spinning arc (or a static ring when `spinning` is false).
struct RingSpinner: NSViewRepresentable {
    var color: NSColor
    var lineWidth: CGFloat = 2.5
    var spinning = true
    var progress: CGFloat = 0.28
    var trackColor: NSColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.08)
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.addSublayer(CAShapeLayer())
        v.layer?.addSublayer(CAShapeLayer())
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let subs = v.layer?.sublayers, subs.count == 2,
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
        track.strokeColor = trackColor.cgColor
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
