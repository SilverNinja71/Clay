import SwiftUI

public enum PaperStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case grid, ruled, dotted, blank
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .grid: "grid"
        case .ruled: "line.3.horizontal"
        case .dotted: "circle.grid.3x3"
        case .blank: "rectangle"
        }
    }
}

/// Mapping between sketch-plane millimetres (y up) and view points (y down).
public struct SketchViewTransform: Equatable, Sendable {
    /// Plane point shown at the centre of the view.
    public var center = Vec2(0, 60)
    /// Points per millimetre.
    public var scale: CGFloat = 3
    public init() {}

    public func toView(_ p: Vec2, size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + CGFloat(p.x - center.x) * scale,
                y: size.height / 2 - CGFloat(p.y - center.y) * scale)
    }

    public func toPlane(_ q: CGPoint, size: CGSize) -> Vec2 {
        Vec2(center.x + Float((q.x - size.width / 2) / scale),
             center.y - Float((q.y - size.height / 2) / scale))
    }

    public mutating func zoom(by f: CGFloat, around q: CGPoint, size: CGSize) {
        let anchor = toPlane(q, size: size)
        scale = min(max(scale * f, 0.3), 60)
        let after = toPlane(q, size: size)
        center += anchor - after
    }

    public mutating func pan(dx: CGFloat, dy: CGFloat) {
        center.x -= Float(dx / scale)
        center.y += Float(dy / scale)
    }

    /// Fits a plane rectangle (with margin) into the view.
    public static func fitting(min lo: Vec2, max hi: Vec2, size: CGSize) -> SketchViewTransform {
        var t = SketchViewTransform()
        let w = max(hi.x - lo.x, 40), h = max(hi.y - lo.y, 40)
        t.center = (lo + hi) / 2
        t.scale = min(size.width / CGFloat(w), size.height / CGFloat(h)) * 0.72
        return t
    }
}

/// Draws Parchment-style paper on the orthographic sketch plane: a ruled, grid, dotted or blank
/// sheet in millimetre spacing, with heavier lines every centimetre and the centre axis.
public enum PaperGridPattern {
    public static func draw(in ctx: inout GraphicsContext, size: CGSize, transform t: SketchViewTransform,
                            style: PaperStyle, theme: StudioTheme) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .color(theme.paper.color))

        // Paper fibre: a faint, deterministic speckle so the sheet doesn't feel digital-flat.
        var speck = Path()
        var seed: UInt32 = 1234567
        for _ in 0..<Int(size.width * size.height / 900) {
            seed = seed &* 1664525 &+ 1013904223
            let x = CGFloat(seed % 10_000) / 10_000 * size.width
            seed = seed &* 1664525 &+ 1013904223
            let y = CGFloat(seed % 10_000) / 10_000 * size.height
            speck.addRect(CGRect(x: x, y: y, width: 1, height: 1))
        }
        ctx.fill(speck, with: .color(theme.ink.color.opacity(theme.isDark ? 0.05 : 0.035)))

        guard style != .blank else { drawAxes(&ctx, size, t, theme); return }
        // Pick a spacing that stays readable at any zoom: 1, 5 or 10 mm.
        let spacings: [Float] = [1, 5, 10, 50]
        let minor = spacings.first { CGFloat($0) * t.scale >= 9 } ?? 50
        let major: Float = minor == 1 ? 10 : (minor == 5 ? 50 : minor * 5)
        let lo = t.toPlane(CGPoint(x: 0, y: size.height), size: size)
        let hi = t.toPlane(CGPoint(x: size.width, y: 0), size: size)
        let line = theme.paperLine.color

        switch style {
        case .grid, .ruled:
            var minorPath = Path(), majorPath = Path()
            func segment(_ isMajor: Bool, _ a: CGPoint, _ b: CGPoint) {
                if isMajor { majorPath.move(to: a); majorPath.addLine(to: b) }
                else { minorPath.move(to: a); minorPath.addLine(to: b) }
            }
            var y = (lo.y / minor).rounded(.down) * minor
            while y <= hi.y {
                let q = t.toView(Vec2(0, y), size: size).y
                let isMajor = abs(y.truncatingRemainder(dividingBy: major)) < 1e-3
                segment(isMajor, CGPoint(x: 0, y: q), CGPoint(x: size.width, y: q))
                y += minor
            }
            if style == .grid {
                var x = (lo.x / minor).rounded(.down) * minor
                while x <= hi.x {
                    let q = t.toView(Vec2(x, 0), size: size).x
                    let isMajor = abs(x.truncatingRemainder(dividingBy: major)) < 1e-3
                    segment(isMajor, CGPoint(x: q, y: 0), CGPoint(x: q, y: size.height))
                    x += minor
                }
            } else {
                // Notebook margin line.
                var margin = Path()
                margin.move(to: CGPoint(x: 64, y: 0)); margin.addLine(to: CGPoint(x: 64, y: size.height))
                ctx.stroke(margin, with: .color(Color(red: 0.85, green: 0.35, blue: 0.35).opacity(0.35)), lineWidth: 1)
            }
            ctx.stroke(minorPath, with: .color(line.opacity(0.55)), lineWidth: 0.5)
            ctx.stroke(majorPath, with: .color(line), lineWidth: 0.9)
        case .dotted:
            var dots = Path()
            var y = (lo.y / minor).rounded(.down) * minor
            while y <= hi.y {
                var x = (lo.x / minor).rounded(.down) * minor
                while x <= hi.x {
                    let q = t.toView(Vec2(x, y), size: size)
                    let r: CGFloat = abs(x.truncatingRemainder(dividingBy: major)) < 1e-3 && abs(y.truncatingRemainder(dividingBy: major)) < 1e-3 ? 1.6 : 0.9
                    dots.addEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2))
                    x += minor
                }
                y += minor
            }
            ctx.fill(dots, with: .color(line))
        case .blank:
            break
        }
        drawAxes(&ctx, size, t, theme)
    }

    private static func drawAxes(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: SketchViewTransform, _ theme: StudioTheme) {
        var axis = Path()
        let x0 = t.toView(Vec2(0, 0), size: size)
        axis.move(to: CGPoint(x: x0.x, y: 0)); axis.addLine(to: CGPoint(x: x0.x, y: size.height))
        ctx.stroke(axis, with: .color(theme.accent.color.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
        var ground = Path()
        ground.move(to: CGPoint(x: 0, y: x0.y)); ground.addLine(to: CGPoint(x: size.width, y: x0.y))
        ctx.stroke(ground, with: .color(theme.ink.color.opacity(0.35)), lineWidth: 1.2)
    }
}
