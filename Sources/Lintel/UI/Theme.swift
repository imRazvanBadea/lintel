import SwiftUI
import AppKit

enum Theme {
    /// One colour per session — distinct at a glance, readable on black.
    static let session: [Color] = [
        Color(hex: 0x7CB8FF), // sky
        Color(hex: 0x8B7CFF), // violet
        Color(hex: 0x5FD39A), // mint
        Color(hex: 0xF5A524), // amber
        Color(hex: 0xFF7AB6), // pink
        Color(hex: 0x4FD1C5), // teal
        Color(hex: 0xF7D154), // lemon
        Color(hex: 0xFF8A65), // coral
        Color(hex: 0xB9A3FF), // lilac
    ]
    static func color(_ i: Int) -> Color { session[i % session.count] }

    static let red = Color(hex: 0xE5484D)
    static let green = Color(hex: 0x46C37B)
    static let amber = Color(hex: 0xF5A524)

    static let primary = Color.white
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    static let hairline = Color.white.opacity(0.08)
    static let fill = Color.white.opacity(0.06)

    static let card = LinearGradient(colors: [Color(white: 0.015), Color(white: 0.07), Color(white: 0.24)],
                                     startPoint: .top, endPoint: .bottom)

    static let mono = Font.system(size: 12.5, weight: .regular, design: .monospaced)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// The dark, softly graded card that drops out of the notch.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 30
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
    }
}

extension View {
    func card(radius: CGFloat = 30) -> some View { modifier(CardBackground(radius: radius)) }
}

/// The small always-visible capsules at the top of the screen.
struct PillBackground: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(Color(white: 0.06))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

/// White primary / dark secondary capsule buttons.
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(kind == .primary ? Color.black : (kind == .quiet ? Theme.secondary : Color.white))
            .padding(.horizontal, 16)
            .frame(height: height)
            .frame(maxWidth: kind == .quiet ? nil : .infinity)
            .background(
                Capsule(style: .continuous).fill(kind == .primary ? Color.white : (kind == .quiet ? Color.clear : Color.white.opacity(0.1)))
            )
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
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
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .contentShape(Circle())
    }
}

/// Hover highlight for list rows.
struct HoverRow: ViewModifier {
    @State private var hover = false
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(hover ? 0.07 : 0)))
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

extension View {
    func hoverRow(radius: CGFloat = 18) -> some View { modifier(HoverRow(radius: radius)) }
}

func relativeTime(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 10 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}
