// The gm-guitars look from 1.0: obsidian and slate surfaces, a warm gold accent, off-white text,
// steel for secondary text, wide-tracked capitals for headings.

import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255,
            opacity: opacity)
    }

    static let obsidian = Color(hex: 0x121212)
    static let slate = Color(hex: 0x1e1e1e)
    static let slate2 = Color(hex: 0x262626)
    static let slate3 = Color(hex: 0x303030)
    static let line = Color(hex: 0x2e2e2e)
    static let lineStrong = Color(hex: 0x3a3a3a)
    static let gold = Color(hex: 0xc5a059)
    static let goldBright = Color(hex: 0xd8b672)
    static let goldDim = Color(hex: 0xc5a059, opacity: 0.14)
    static let offwhite = Color(hex: 0xe0e0e0)
    static let steel = Color(hex: 0x8e8e8e)
    static let steelDim = Color(hex: 0x5f5f5f)
    static let ok = Color(hex: 0x6fbf73)
    static let warn = Color(hex: 0xe0a43a)
    static let danger = Color(hex: 0xd9534f)
    static let dangerDim = Color(hex: 0xd9534f, opacity: 0.16)
    static let info = Color(hex: 0x6aa5d9)
    static let axisX = Color(hex: 0xd96b6b)
    static let axisY = Color(hex: 0x7fbf6a)
    static let axisZ = Color(hex: 0x6a9fd9)
}

extension Font {
    static let heading = Font.custom("Helvetica", size: 11).weight(.bold)
    static let mono = Font.system(size: 12, design: .monospaced)
}

/// Small wide-tracked capitals above a section.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.heading).tracking(1.6).foregroundStyle(Color.steel)
    }
}

enum ButtonKind {
    case normal, primary, outlineGold, warn, danger, ghost, go, amber, red
}

struct GCCButtonStyle: ButtonStyle {
    var kind: ButtonKind = .normal
    var size: ControlSize = .regular
    var active = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let (fill, stroke, text) = colors
        configuration.label
            .font(size == .large ? .system(size: 14, weight: .semibold) : size == .small ? .system(size: 11.5) : .system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, size == .small ? 8 : 12)
            .padding(.vertical, size == .large ? 10 : size == .small ? 4 : 7)
            .frame(minWidth: size == .small ? 0 : 36)
            .foregroundStyle(text)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill.opacity(configuration.isPressed ? 0.75 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(stroke, lineWidth: 1))
            .opacity(enabled ? 1 : 0.38)
            .contentShape(Rectangle())
    }

    private var colors: (Color, Color, Color) {
        if active { return (.goldDim, .gold, .goldBright) }
        switch kind {
        case .normal: return (.slate3, .lineStrong, .offwhite)
        case .primary: return (.gold, .gold, .obsidian)
        case .outlineGold: return (.clear, .gold, .gold)
        case .warn: return (Color.warn.opacity(0.18), .warn, .warn)
        case .danger: return (.dangerDim, .danger, Color(hex: 0xf08a86))
        case .ghost: return (.clear, .clear, .steel)
        case .amber: return (Color(hex: 0xb7791f), Color(hex: 0xe0a030), .white)
        case .red: return (Color(hex: 0xa8322d), Color(hex: 0xd9534f), .white)
        case .go: return (Color(hex: 0x2f8f4e), Color(hex: 0x46b86a), .white)
        }
    }
}

extension View {
    func gccButton(_ kind: ButtonKind = .normal, _ size: ControlSize = .regular, active: Bool = false) -> some View {
        buttonStyle(GCCButtonStyle(kind: kind, size: size, active: active))
    }

    /// Full width inside a grid or stack.
    func wide() -> some View { frame(maxWidth: .infinity) }
}

/// A slate card with a heading, like 1.0's `.panel`.
struct Panel<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty {
                HStack {
                    Text(title.uppercased()).font(.heading).tracking(1.8).foregroundStyle(Color.offwhite)
                    Spacer()
                    accessory
                }
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.slate))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line))
    }
}

extension Panel where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { self.init(title, accessory: { EmptyView() }, content: content) }
}

/// A small rounded label: a file's source, a conflict.
struct Badge: View {
    let text: String
    var color: Color = .steel
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct Dot: View {
    let ok: Bool
    var body: some View { Circle().fill(ok ? Color.ok : Color.danger).frame(width: 7, height: 7) }
}

struct Pill<Content: View>: View {
    var tint: Color = .slate2
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 6) { content }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(tint))
            .overlay(Capsule().strokeBorder(Color.line))
    }
}

/// A text field in the app's style.
struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.obsidian))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.lineStrong))
    }
}

extension View {
    func gccField() -> some View { modifier(FieldStyle()) }
}
