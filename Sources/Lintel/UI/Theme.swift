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
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.09))
    static let fill = dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.07))
    static let fillStrong = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.12))
    /// Fill of the main action (black in light mode, white in dark) and the text on it.
    static let action = dynamic(light: NSColor(hex: 0x0D0D0D), dark: .white)
    static let onAction = dynamic(light: .white, dark: .black)
    /// Selected segment in the phase strip.
    static let raised = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.1))
    /// Avatar ring separating overlapping avatars.
    static let capsuleFill = dynamic(light: .white, dark: NSColor(white: 0.07, alpha: 1))

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

/// The card that drops out of the notch / capsule: a soft top-to-bottom grade for depth.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 24
    @Environment(\.colorScheme) private var scheme

    private var gradient: LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color(white: 0.015), Color(white: 0.07), Color(white: 0.22)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color.white, Color(white: 0.985), Color(hex: 0xEEEEF1)], startPoint: .top, endPoint: .bottom)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(gradient))
            // A faint highlight along the top edge gives the light card a little lift.
            .overlay(shape.strokeBorder(
                LinearGradient(colors: scheme == .dark ? [Color.white.opacity(0.12), Color.white.opacity(0.05)]
                                                       : [Color.white, Color.black.opacity(0.07)],
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
        Capsule(style: .continuous)
            .fill(scheme == .dark
                  ? LinearGradient(colors: [Color(white: 0.04), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                  : LinearGradient(colors: [Color.white, Color(hex: 0xF3F3F5)], startPoint: .top, endPoint: .bottom))
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 8, y: 3)
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
