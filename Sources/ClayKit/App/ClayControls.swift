import SwiftUI

// Theme-matched controls for the floating panels (instead of stock system sliders, checkboxes
// and pop-up menus, which ignore the Clay colourways).

/// A pill-shaped slider: the name and value sit inside the bar; drag anywhere on it.
public struct ClaySlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format: (Float) -> String
    let theme: StudioTheme
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false

    public init(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>, theme: StudioTheme,
                format: @escaping (Float) -> String, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; _value = value; self.range = range; self.theme = theme
        self.format = format; self.onEditingChanged = onEditingChanged
    }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? CGFloat(min(max((value - range.lowerBound) / span, 0), 1)) : 0
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = max(14, w * fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.canvas.color.opacity(theme.isDark ? 0.55 : 0.75))
                Capsule()
                    .fill(LinearGradient(colors: [theme.accent.color.opacity(0.16), theme.accent.color.opacity(dragging ? 0.5 : 0.38)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(alignment: .trailing) {
                        Capsule().strokeBorder(theme.accent.color.opacity(0.55), lineWidth: 1)
                    }
                    .frame(width: fill)
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 6)
                    Text(format(value)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(theme.ink.color)
                .padding(.leading, 14).padding(.trailing, 12)
            }
            .overlay(Capsule().strokeBorder(dragging ? theme.accent.color.opacity(0.6) : theme.panelStroke.color))
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                if !dragging { dragging = true; onEditingChanged(true) }
                let f = Float(min(max(g.location.x / max(w, 1), 0), 1))
                value = range.lowerBound + f * (range.upperBound - range.lowerBound)
            }.onEnded { _ in
                dragging = false
                onEditingChanged(false)
            })
        }
        .frame(height: 32)
        .animation(.easeOut(duration: 0.12), value: dragging)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) * 0.05
            onEditingChanged(true)
            value = min(max(value + (dir == .increment ? step : -step), range.lowerBound), range.upperBound)
            onEditingChanged(false)
        }
    }
}

/// An on/off chip with an icon (replaces checkboxes).
public struct ClayToggleChip: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    let theme: StudioTheme

    public init(_ title: String, symbol: String, isOn: Binding<Bool>, theme: StudioTheme) {
        self.title = title; self.symbol = symbol; _isOn = isOn; self.theme = theme
    }

    public var body: some View {
        Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { isOn.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isOn ? theme.onAccent.color : theme.ink.color)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isOn ? theme.accent.color : theme.canvas.color.opacity(theme.isDark ? 0.5 : 0.7)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isOn ? .clear : theme.panelStroke.color))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A segmented control with a sliding accent capsule.
public struct ClaySegmented<T: Hashable>: View {
    public struct Option {
        public var value: T
        public var label: String?
        public var symbol: String?
        public init(_ value: T, _ label: String? = nil, symbol: String? = nil) { self.value = value; self.label = label; self.symbol = symbol }
    }
    let options: [Option]
    @Binding var selection: T
    let theme: StudioTheme
    @Namespace private var ns

    public init(_ options: [Option], selection: Binding<T>, theme: StudioTheme) {
        self.options = options; _selection = selection; self.theme = theme
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let selected = o.value == selection
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = o.value } } label: {
                    HStack(spacing: 5) {
                        if let s = o.symbol { Image(systemName: s).font(.system(size: 12, weight: .semibold)) }
                        if let l = o.label { Text(l).font(.system(size: 12, weight: .semibold)).lineLimit(1) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selected ? theme.onAccent.color : theme.ink.color)
                    .background {
                        if selected { Capsule().fill(theme.accent.color).matchedGeometryEffect(id: "segment", in: ns) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(o.label ?? "")
            }
        }
        .padding(3)
        .background(Capsule().fill(theme.canvas.color.opacity(theme.isDark ? 0.5 : 0.7)))
        .overlay(Capsule().strokeBorder(theme.panelStroke.color))
    }
}

/// Brush falloff choices, each drawn as its curve.
public struct FalloffPicker: View {
    @Binding var selection: Falloff
    let theme: StudioTheme

    public init(selection: Binding<Falloff>, theme: StudioTheme) { _selection = selection; self.theme = theme }

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(Falloff.allCases, id: \.self) { f in
                let selected = f == selection
                Button { withAnimation(.spring(response: 0.25)) { selection = f } } label: {
                    VStack(spacing: 3) {
                        Canvas { ctx, size in
                            var p = Path()
                            let n = 40
                            p.move(to: CGPoint(x: 0, y: size.height))
                            for i in 0...n {
                                let x = CGFloat(i) / CGFloat(n)
                                let w = CGFloat(f.weight(Float(abs(x * 2 - 1))))
                                p.addLine(to: CGPoint(x: x * size.width, y: size.height - w * (size.height - 2)))
                            }
                            p.addLine(to: CGPoint(x: size.width, y: size.height))
                            p.closeSubpath()
                            let c = selected ? theme.onAccent.color : theme.accent.color
                            ctx.fill(p, with: .color(c.opacity(selected ? 0.35 : 0.2)))
                            ctx.stroke(p, with: .color(c), lineWidth: 1.5)
                        }
                        .frame(height: 20)
                        Text(f.rawValue.capitalized).font(.system(size: 10, weight: .semibold))
                    }
                    .padding(6)
                    .foregroundStyle(selected ? theme.onAccent.color : theme.ink.color)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? theme.accent.color : theme.canvas.color.opacity(theme.isDark ? 0.5 : 0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? .clear : theme.panelStroke.color))
                }
                .buttonStyle(PressableStyle())
                .help("\(f.rawValue.capitalized) falloff")
            }
        }
    }
}

/// Rounded action buttons for panels.
public struct ClayPillButtonStyle: ButtonStyle {
    let theme: StudioTheme
    var prominent = false
    public init(theme: StudioTheme, prominent: Bool = false) { self.theme = theme; self.prominent = prominent }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .labelStyle(TightLabel())
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(prominent ? theme.onAccent.color : theme.ink.color)
            .background(Capsule().fill(prominent ? theme.accent.color : theme.canvas.color.opacity(theme.isDark ? 0.5 : 0.75)))
            .overlay(Capsule().strokeBorder(prominent ? .clear : theme.panelStroke.color))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
