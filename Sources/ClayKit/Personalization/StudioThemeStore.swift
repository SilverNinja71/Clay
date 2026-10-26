import SwiftUI
import Observation
import simd

/// An sRGB colour that is Codable and converts to SwiftUI and to linear space for Metal.
public struct RGBA: Codable, Equatable, Hashable, Sendable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }
    public var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    /// sRGB → linear (the viewport renders into an sRGB drawable, which converts back).
    public var linear: Vec4 {
        func l(_ c: Double) -> Float { Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)) }
        return Vec4(l(r), l(g), l(b), Float(a))
    }
    public func mix(_ o: RGBA, _ t: Double) -> RGBA {
        RGBA(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t, a + (o.a - a) * t)
    }
    public func opacity(_ x: Double) -> RGBA { RGBA(r, g, b, x) }
}

/// A workspace colourway: UI chrome, paper, and the 3D studio lighting.
public struct StudioTheme: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isDark: Bool
    // Chrome
    public var canvas: RGBA
    public var panel: RGBA
    public var panelStroke: RGBA
    public var ink: RGBA
    public var secondaryInk: RGBA
    public var accent: RGBA
    public var onAccent: RGBA
    // Paper
    public var paper: RGBA
    public var paperLine: RGBA
    public var sketchInk: RGBA
    public var ghostInk: RGBA
    public var guideInk: RGBA
    // 3D studio
    public var clay: RGBA
    public var rim: RGBA
    public var sky: RGBA
    public var ground: RGBA
    public var bgTop: RGBA
    public var bgBottom: RGBA
    public var grid: RGBA
    public var wire: RGBA

    public static let ceramic = StudioTheme(
        id: "ceramic", name: "Ceramic", isDark: false,
        canvas: RGBA(hex: 0xEDE8E1), panel: RGBA(hex: 0xFBF8F4, alpha: 0.92), panelStroke: RGBA(hex: 0x2B2420, alpha: 0.08),
        ink: RGBA(hex: 0x2B2420), secondaryInk: RGBA(hex: 0x7A6E66), accent: RGBA(hex: 0xC2643C), onAccent: RGBA(hex: 0xFFFFFF),
        paper: RGBA(hex: 0xF7F2E8), paperLine: RGBA(hex: 0x9FB7C9, alpha: 0.45), sketchInk: RGBA(hex: 0x2E2A27),
        ghostInk: RGBA(hex: 0xC2643C, alpha: 0.35), guideInk: RGBA(hex: 0x3D7EA6, alpha: 0.55),
        clay: RGBA(hex: 0xC98B6B), rim: RGBA(hex: 0xFFE7D2, alpha: 0.32), sky: RGBA(hex: 0xF2EEE8), ground: RGBA(hex: 0x8C6E5D),
        bgTop: RGBA(hex: 0xEEE9E2), bgBottom: RGBA(hex: 0xCFC7BD), grid: RGBA(hex: 0x5C5048, alpha: 0.32), wire: RGBA(hex: 0x3A2A22, alpha: 0.28))

    public static let darkSlate = StudioTheme(
        id: "darkSlate", name: "Dark Slate", isDark: true,
        canvas: RGBA(hex: 0x1B1E22), panel: RGBA(hex: 0x272B31, alpha: 0.92), panelStroke: RGBA(hex: 0xFFFFFF, alpha: 0.08),
        ink: RGBA(hex: 0xECEFF2), secondaryInk: RGBA(hex: 0x9AA3AD), accent: RGBA(hex: 0x6FB1FF), onAccent: RGBA(hex: 0x0B1220),
        paper: RGBA(hex: 0x23272C), paperLine: RGBA(hex: 0x8FA3B8, alpha: 0.18), sketchInk: RGBA(hex: 0xE9EDF1),
        ghostInk: RGBA(hex: 0x6FB1FF, alpha: 0.35), guideInk: RGBA(hex: 0xF0B35E, alpha: 0.6),
        clay: RGBA(hex: 0xB9A99B), rim: RGBA(hex: 0x9FC7FF, alpha: 0.38), sky: RGBA(hex: 0xC8D2DE), ground: RGBA(hex: 0x3B3E44),
        bgTop: RGBA(hex: 0x2C3138), bgBottom: RGBA(hex: 0x15171A), grid: RGBA(hex: 0xB8C2CC, alpha: 0.22), wire: RGBA(hex: 0xFFFFFF, alpha: 0.18))

    public static let blueprint = StudioTheme(
        id: "blueprint", name: "Blueprint", isDark: true,
        canvas: RGBA(hex: 0x0F3057), panel: RGBA(hex: 0x163D6B, alpha: 0.92), panelStroke: RGBA(hex: 0xFFFFFF, alpha: 0.12),
        ink: RGBA(hex: 0xF2F7FF), secondaryInk: RGBA(hex: 0xA9C2E2), accent: RGBA(hex: 0xFFD166), onAccent: RGBA(hex: 0x0F3057),
        paper: RGBA(hex: 0x1A4A80), paperLine: RGBA(hex: 0xDDEBFF, alpha: 0.22), sketchInk: RGBA(hex: 0xFFFFFF),
        ghostInk: RGBA(hex: 0xFFD166, alpha: 0.4), guideInk: RGBA(hex: 0x9EE6FF, alpha: 0.6),
        clay: RGBA(hex: 0xD9E4F2), rim: RGBA(hex: 0x9EE6FF, alpha: 0.45), sky: RGBA(hex: 0xDDEBFF), ground: RGBA(hex: 0x2B5A8E),
        bgTop: RGBA(hex: 0x1E5390), bgBottom: RGBA(hex: 0x0D2A4D), grid: RGBA(hex: 0xDDEBFF, alpha: 0.28), wire: RGBA(hex: 0x0F3057, alpha: 0.4))

    public static let all: [StudioTheme] = [.ceramic, .darkSlate, .blueprint]

    public var palette: RenderPalette {
        var p = RenderPalette()
        p.clay = clay.linear; p.rim = rim.linear; p.rim.w = Float(rim.a)
        p.sky = sky.linear; p.ground = ground.linear
        p.bgTop = bgTop.linear; p.bgBottom = bgBottom.linear
        p.grid = grid.linear; p.grid.w = Float(grid.a)
        p.wire = wire.linear; p.wire.w = Float(wire.a)
        p.brush = isDark ? Vec4(1, 1, 1, 0.85) : Vec4(0.15, 0.1, 0.08, 0.75)
        return p
    }
}

/// The selected colourway, remembered between launches.
@MainActor @Observable
public final class StudioThemeStore {
    public var current: StudioTheme {
        didSet { UserDefaults.standard.set(current.id, forKey: "Clay.theme") }
    }

    public init() {
        let id = UserDefaults.standard.string(forKey: "Clay.theme")
        current = StudioTheme.all.first { $0.id == id } ?? .ceramic
    }

    public init(theme: StudioTheme) { current = theme }
}

// MARK: - Shared chrome styles

public struct FloatingPanel: ViewModifier {
    var theme: StudioTheme
    var radius: CGFloat = 16
    public func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(theme.panel.color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(theme.panelStroke.color, lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 14, y: 6)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

public extension View {
    func floatingPanel(_ theme: StudioTheme, radius: CGFloat = 16) -> some View {
        modifier(FloatingPanel(theme: theme, radius: radius))
    }
}

/// Round tool button used across the floating toolbars.
public struct ToolButton: View {
    var symbol: String
    var label: String
    var isOn: Bool
    var theme: StudioTheme
    var size: CGFloat = 38
    var action: () -> Void

    public init(symbol: String, label: String, isOn: Bool = false, theme: StudioTheme, size: CGFloat = 38, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.isOn = isOn; self.theme = theme; self.size = size; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(isOn ? theme.onAccent.color : theme.ink.color)
                .background(Circle().fill(isOn ? theme.accent.color : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isOn)
    }
}

public struct PressableStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
