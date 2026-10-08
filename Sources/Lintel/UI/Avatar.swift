import SwiftUI
import AppKit
import QuartzCore

/// A session's badge: a softly graded circle with the first letter of its project.
/// While the agent works, a spinning border orbits it (drawn as an overlay, so it never changes the size).
struct Avatar: View {
    let session: AgentSession
    var size: CGFloat = 28
    var showsActivity = true

    private var ring: CGFloat { size + max(7, size * 0.3) }

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [session.tint.lighter, session.tint, session.tint.darker],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75))
            .overlay(
                Text(session.initial)
                    .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            )
            .frame(width: size, height: size)
            .opacity(session.status == .finished ? 0.7 : (session.status == .idle ? 0.5 : 1))
            .overlay {
                if showsActivity {
                    switch session.status {
                    case .working:
                        RingSpinner(color: NSColor(session.tint), lineWidth: max(1.5, size * 0.06), progress: 0.3)
                            .frame(width: ring, height: ring)
                            .allowsHitTesting(false)
                    case .waiting:
                        Circle().strokeBorder(Theme.amber, lineWidth: max(1.5, size * 0.06))
                            .frame(width: ring, height: ring)
                    default:
                        EmptyView()
                    }
                }
            }
    }
}

extension Color {
    var lighter: Color { Color(nsColor: NSColor(self).blended(withFraction: 0.28, of: .white) ?? NSColor(self)) }
    var darker: Color { Color(nsColor: NSColor(self).blended(withFraction: 0.22, of: .black) ?? NSColor(self)) }
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

    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }

    func updateNSView(_ v: SpinnerView, context: Context) {
        v.color = color
        v.trackColor = trackColor
        v.lineWidth = lineWidth
        v.progress = progress
        v.spinning = spinning
        v.needsLayout = true
    }
}

/// Lays its layers out whenever its size changes (SwiftUI often creates it at zero size first).
final class SpinnerView: NSView {
    var color: NSColor = .white
    var trackColor: NSColor = .clear
    var lineWidth: CGFloat = 2
    var progress: CGFloat = 0.28
    var spinning = true

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(arc)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = b.width > 0 ? CGPath(ellipseIn: b, transform: nil) : nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for l in [track, arc] {
                l.frame = bounds
                l.path = path
                l.fillColor = nil
                l.lineWidth = lineWidth
                l.lineCap = .round
            }
            track.strokeColor = trackColor.cgColor
            arc.strokeColor = color.cgColor
        }
        arc.strokeEnd = progress
        CATransaction.commit()
        updateAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func updateAnimation() {
        if spinning, window != nil, bounds.width > 0 {
            guard arc.animation(forKey: "spin") == nil else { return }
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = -2 * CGFloat.pi
            a.duration = 1.1
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            arc.add(a, forKey: "spin")
        } else if !spinning {
            arc.removeAnimation(forKey: "spin")
        }
    }
}

/// Little equaliser bars that bounce while music plays.
struct Equalizer: NSViewRepresentable {
    var color: NSColor
    var playing: Bool
    var bars = 4

    func makeNSView(context: Context) -> EqualizerView { EqualizerView(bars: bars) }

    func updateNSView(_ v: EqualizerView, context: Context) {
        v.color = color
        v.playing = playing
        v.needsLayout = true
    }
}

final class EqualizerView: NSView {
    var color: NSColor = .white
    var playing = false
    private var layers: [CALayer] = []

    init(bars: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<bars {
            let l = CALayer()
            l.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(l)
            layers.append(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }

    override func layout() {
        super.layout()
        let b = bounds
        guard b.width > 0 else { return }
        let n = CGFloat(layers.count)
        let gap: CGFloat = 2
        let w = (b.width - gap * (n - 1)) / n
        let durations: [Double] = [0.42, 0.55, 0.36, 0.48, 0.6]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in layers.enumerated() {
            effectiveAppearance.performAsCurrentDrawingAppearance { l.backgroundColor = color.cgColor }
            l.cornerRadius = w / 2
            l.bounds = CGRect(x: 0, y: 0, width: w, height: b.height)
            l.position = CGPoint(x: CGFloat(i) * (w + gap) + w / 2, y: 0)
            if playing && window != nil {
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
