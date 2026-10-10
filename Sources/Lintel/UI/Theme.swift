import SwiftUI
import AppKit

/// Quiet and typographic in light mode (white, hairlines, black actions); deep graded black in dark mode.
/// Every token resolves against the panel's appearance, which follows Settings › Appearance.
enum Theme {
    /// One colour per session — distinct at a glance on white, on black and on the notch.
    static let session: [Color] = [
        Color(hex: 0x3B82F6), // blue
        Color(hex: 0x8B5CF6), // violet
        Color(hex: 0x10A37F), // green
        Color(hex: 0xF97316), // orange
        Color(hex: 0xEC4899), // pink
        Color(hex: 0x0EA5A4), // teal
        Color(hex: 0xCA8A04), // ochre
        Color(hex: 0xE5484D), // red
        Color(hex: 0x6366F1), // indigo
    ]
    static func color(_ i: Int) -> Color { session[i % session.count] }

    static let red = Color(hex: 0xE5484D)
    static let green = Color(hex: 0x10A37F)
    static let amber = Color(hex: 0xE8930C)

    static let primary = dynamic(light: NSColor(hex: 0x0D0D0D), dark: .white)
    static let secondary = dynamic(light: NSColor(hex: 0x5D5D5D), dark: NSColor(white: 1, alpha: 0.58))
    static let tertiary = dynamic(light: NSColor(hex: 0x8F8F8F), dark: NSColor(white: 1, alpha: 0.36))
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.055))
    static let fill = dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.07))
    static let fillStrong = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.12))
    /// Fill of the main action (black in light mode, white in dark) and the text on it.
    static let action = dynamic(light: NSColor(hex: 0x0D0D0D), dark: .white)
    static let onAction = dynamic(light: .white, dark: .black)
    /// Selected segment in the phase strip.
    static let raised = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.1))

    static let mono = Font.system(size: 12.5, weight: .regular, design: .monospaced)

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// Frosted glass that blurs whatever is behind the window (desktop, other apps).
/// A nil radius rounds it into a capsule.
struct BehindWindowBlur: NSViewRepresentable {
    var radius: CGFloat?

    final class View: NSVisualEffectView {
        var radius: CGFloat?
        override func layout() {
            super.layout()
            layer?.cornerRadius = radius ?? bounds.height / 2
        }
    }

    func makeNSView(context: Context) -> View {
        let v = View()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: View, context: Context) {
        v.radius = radius
        v.needsLayout = true
    }
}

/// The see-through grey grade laid over `BehindWindowBlur` in dark mode (cards and capsules).
let darkGlassTint = LinearGradient(colors: [Color(white: 0.04), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
let darkGlassTintOpacity = 0.45

/// The card that drops out of the notch / capsule. Dark: a faint, see-through grey grade over a
/// behind-window blur. Light: a soft top-to-bottom grade.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 24
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder private func fill(_ shape: RoundedRectangle) -> some View {
        if scheme == .dark {
            ZStack {
                BehindWindowBlur(radius: radius)
                shape.fill(darkGlassTint).opacity(darkGlassTintOpacity)
            }
        } else {
            shape.fill(LinearGradient(colors: [Color.white, Color(white: 0.985), Color(hex: 0xEEEEF1)],
                                      startPoint: .top, endPoint: .bottom))
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(fill(shape))
            // A faint highlight along the top edge gives the light card a little lift.
            .overlay(shape.strokeBorder(
                LinearGradient(colors: scheme == .dark ? [Color.white.opacity(0.07), Color.white.opacity(0.025)]
                                                       : [Color.white, Color.black.opacity(0.045)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.12), radius: 28, y: 14)
            .shadow(color: .black.opacity(scheme == .dark ? 0.2 : 0.05), radius: 2, y: 1)
    }
}

extension View {
    func card(radius: CGFloat = 24) -> some View { modifier(CardBackground(radius: radius)) }
}

/// The capsules at the top of an external display.
struct CapsuleBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        fill
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 8, y: 3)
    }

    /// Dark: the same frosted glass as the card, so capsule and card read as one material.
    @ViewBuilder private var fill: some View {
        let shape = Capsule(style: .continuous)
        if scheme == .dark {
            ZStack {
                BehindWindowBlur(radius: nil)
                shape.fill(darkGlassTint).opacity(darkGlassTintOpacity)
            }
        } else {
            shape.fill(LinearGradient(colors: [Color.white, Color(hex: 0xF3F3F5)], startPoint: .top, endPoint: .bottom))
        }
    }
}

/// The notch, extended: flat top flush with the screen edge, small flared "ears" where it meets the
/// menu bar, rounded bottom corners — the same silhouette as the hardware notch.
struct NotchShape: Shape {
    var ear: CGFloat = 6
    var bottomRadius: CGFloat = 12

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(ear, bottomRadius) }
        set { ear = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, e = ear, b = min(bottomRadius, h / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: e, y: e), control: CGPoint(x: e, y: 0))
        p.addLine(to: CGPoint(x: e, y: h - b))
        p.addQuadCurve(to: CGPoint(x: e + b, y: h), control: CGPoint(x: e, y: h))
        p.addLine(to: CGPoint(x: w - e - b, y: h))
        p.addQuadCurve(to: CGPoint(x: w - e, y: h - b), control: CGPoint(x: w - e, y: h))
        p.addLine(to: CGPoint(x: w - e, y: e))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - e, y: 0))
        p.closeSubpath()
        return p
    }
}

/// Primary (black in light, white in dark) / quiet grey secondary pill buttons.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(kind == .primary ? Theme.onAction : (kind == .quiet ? Theme.secondary : Theme.primary))
            .padding(.horizontal, kind == .quiet ? 8 : 16)
            .frame(height: height)
            .frame(maxWidth: kind == .quiet ? nil : .infinity)
            .background(
                Capsule(style: .continuous).fill(kind == .primary ? Theme.action : (kind == .quiet ? Color.clear : Theme.fill))
            )
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(configuration.isPressed ? Theme.fillStrong : Theme.fill))
            .contentShape(Circle())
    }
}

/// Hover highlight for list rows.
struct HoverRow: ViewModifier {
    @State private var hover = false
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hover ? Theme.fill : .clear))
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

extension View {
    func hoverRow(radius: CGFloat = 14) -> some View { modifier(HoverRow(radius: radius)) }
}

func relativeTime(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 10 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}

/// A small info icon that explains itself in a popover on hover.
struct InfoTip: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 10.5))
            .foregroundStyle(shown ? Theme.secondary : Theme.tertiary)
            .contentShape(Rectangle())
            .onHover { shown = $0 }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 220, alignment: .leading)
                    .padding(10)
            }
    }
}
