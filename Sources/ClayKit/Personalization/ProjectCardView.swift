import SwiftUI

// MARK: - Preview area

/// The top of a project card: the cover material as a backdrop, with the 3D model floating on it
/// (or the emblem when there's no model yet), plus the hand-drawn doodle.
public struct ProjectPreview: View {
    let cover: ProjectCover
    let thumbnail: CGImage?
    var emblemBadge = true

    public init(cover: ProjectCover, thumbnail: CGImage?, emblemBadge: Bool = true) {
        self.cover = cover; self.thumbnail = thumbnail; self.emblemBadge = emblemBadge
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let ink = cover.inkColor
            ZStack {
                Canvas { ctx, size in CoverMaterialPainter.paint(&ctx, size: size, material: cover.material, tint: cover.tint) }
                LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)

                if cover.showThumbnail, let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 9, y: 7)
                        .padding(.vertical, h * 0.06)
                        .padding(.horizontal, w * 0.12)
                } else if let emblem = cover.emblem {
                    Image(systemName: emblem)
                        .font(.system(size: min(w, h) * 0.34, weight: .regular))
                        .foregroundStyle(ink.opacity(0.85))
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                }

                if !cover.doodle.isEmpty {
                    Canvas { ctx, size in
                        for stroke in cover.doodle where stroke.count > 1 {
                            var p = Path()
                            p.addLines(stroke.map { CGPoint(x: CGFloat($0.x) * size.width, y: CGFloat($0.y) * size.height) })
                            ctx.stroke(p, with: .color(ink.opacity(0.9)), style: StrokeStyle(lineWidth: max(1.5, size.width * 0.01), lineCap: .round, lineJoin: .round))
                        }
                    }
                    .allowsHitTesting(false)
                }

                if emblemBadge, cover.showThumbnail, thumbnail != nil, let emblem = cover.emblem {
                    Image(systemName: emblem)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ink)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.black.opacity(cover.isDark ? 0.25 : 0.08)))
                        .overlay(Circle().strokeBorder(ink.opacity(0.25)))
                        .position(x: 22, y: 22)
                }
            }
            .frame(width: w, height: h)
        }
        .clipped()
    }
}

extension ProjectCover {
    var isDark: Bool { (tint.r * 0.3 + tint.g * 0.59 + tint.b * 0.11) < 0.5 }
    var inkColor: Color { isDark ? .white.opacity(0.92) : Color(white: 0.12) }
}

// MARK: - Overview pieces

/// "120 mm tall · 76 × 66 mm", volume and print-readiness, from the last save.
struct ProjectFacts: View {
    let summary: ProjectSummary
    let theme: StudioTheme
    var detailed = false

    var body: some View {
        let units = summary.units ?? .mm
        HStack(spacing: 10) {
            if let s = summary.stats {
                fact("ruler", "\(units.format(s.size.y)) tall")
                if detailed {
                    fact("cube", "\(units.format(s.size.x, withSymbol: false)) × \(units.format(s.size.z))")
                    fact("drop", String(format: "%.0f cm³", s.volume / 1000))
                }
            } else {
                fact("pencil.and.outline", "Sketch only")
            }
            fact("clock.arrow.circlepath", "\(summary.steps?.count ?? summary.featureCount) steps")
        }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(theme.secondaryInk.color)
            .lineLimit(1)
            .labelStyle(TightLabel())
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.imageScale(.small); configuration.title }
    }
}

/// The project's timeline as a row of small step icons.
struct StepStrip: View {
    let steps: [ProjectStepInfo]
    let theme: StudioTheme
    var limit = 6
    var showNames = false

    var body: some View {
        HStack(spacing: showNames ? 6 : 4) {
            ForEach(Array(steps.prefix(limit).enumerated()), id: \.offset) { i, s in
                if showNames {
                    HStack(spacing: 4) {
                        Image(systemName: s.symbol).font(.system(size: 10, weight: .semibold))
                        Text(s.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(theme.canvas.color.opacity(0.7)))
                    .overlay(Capsule().strokeBorder(theme.panelStroke.color))
                } else {
                    Image(systemName: s.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(i == steps.count - 1 ? theme.accent.color.opacity(0.18) : theme.canvas.color.opacity(0.8)))
                        .overlay(Circle().strokeBorder(theme.panelStroke.color))
                        .help(s.name)
                }
            }
            if steps.count > limit {
                Text("+\(steps.count - limit)").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondaryInk.color)
            }
        }
        .foregroundStyle(theme.ink.color)
    }
}

struct PrintReadyBadge: View {
    let theme: StudioTheme
    var body: some View {
        Label("Print-ready", systemImage: "checkmark.seal.fill")
            .font(.system(size: 10, weight: .bold))
            .labelStyle(TightLabel())
            .foregroundStyle(Color(red: 0.2, green: 0.62, blue: 0.38))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color(red: 0.2, green: 0.62, blue: 0.38).opacity(0.13)))
            .help("Watertight: ready to export for 3D printing")
    }
}

// MARK: - Grid card

/// Library card: model preview on the project's cover material, then a short overview.
public struct ProjectCardView: View {
    let summary: ProjectSummary
    let thumbnail: CGImage?
    let theme: StudioTheme
    @State private var hovering = false

    public init(summary: ProjectSummary, thumbnail: CGImage?, theme: StudioTheme) {
        self.summary = summary; self.thumbnail = thumbnail; self.theme = theme
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectPreview(cover: summary.cover, thumbnail: thumbnail)
                .frame(height: 158)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(summary.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.ink.color).lineLimit(1)
                    Spacer(minLength: 4)
                    if summary.stats?.watertight == true { PrintReadyBadge(theme: theme) }
                }
                Text("Edited \(summary.modified.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11)).foregroundStyle(theme.secondaryInk.color)
                ProjectFacts(summary: summary, theme: theme)
                if let steps = summary.steps, !steps.isEmpty { StepStrip(steps: steps, theme: theme) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.panel.color)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(hovering ? theme.accent.color.opacity(0.6) : theme.panelStroke.color, lineWidth: hovering ? 1.5 : 1))
        .shadow(color: .black.opacity(hovering ? (theme.isDark ? 0.45 : 0.18) : (theme.isDark ? 0.3 : 0.08)), radius: hovering ? 16 : 8, y: hovering ? 9 : 4)
        .scaleEffect(hovering ? 1.015 : 1)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { hovering = h } }
    }
}

// MARK: - Library overview

/// "Continue" panel for the most recently edited project.
struct FeaturedProjectView: View {
    let summary: ProjectSummary
    let thumbnail: CGImage?
    let theme: StudioTheme
    let onOpen: () -> Void
    let onCover: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ProjectPreview(cover: summary.cover, thumbnail: thumbnail)
                .frame(width: 300)
            VStack(alignment: .leading, spacing: 10) {
                Text("CONTINUE WHERE YOU LEFT OFF").font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(theme.accent.color)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(summary.name).font(.system(size: 24, weight: .bold, design: .serif)).foregroundStyle(theme.ink.color).lineLimit(1)
                    if summary.stats?.watertight == true { PrintReadyBadge(theme: theme) }
                }
                Text("Edited \(summary.modified.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12)).foregroundStyle(theme.secondaryInk.color)
                ProjectFacts(summary: summary, theme: theme, detailed: true)
                if let steps = summary.steps, !steps.isEmpty {
                    StepStrip(steps: steps, theme: theme, limit: 5, showNames: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(action: onOpen) {
                        Label("Open project", systemImage: "arrow.right.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .foregroundStyle(theme.onAccent.color)
                            .background(Capsule().fill(theme.accent.color))
                    }
                    .buttonStyle(PressableStyle())
                    Button(action: onCover) {
                        Label("Change cover", systemImage: "paintpalette")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .foregroundStyle(theme.ink.color)
                            .background(Capsule().fill(theme.canvas.color.opacity(0.8)))
                            .overlay(Capsule().strokeBorder(theme.panelStroke.color))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 220)
        .background(theme.panel.color)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.panelStroke.color))
        .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.1), radius: 12, y: 6)
    }
}

/// Small stat tiles across the top of the library.
struct LibraryStats: View {
    let projects: [ProjectSummary]
    let theme: StudioTheme

    var body: some View {
        let sculpted = projects.filter(\.isSculpted).count
        let ready = projects.filter { $0.stats?.watertight == true }.count
        let clay = projects.compactMap { $0.stats?.volume }.reduce(0, +) / 1000
        HStack(spacing: 10) {
            tile("square.grid.2x2", "\(projects.count)", projects.count == 1 ? "Project" : "Projects")
            tile(FeatureKind.sculptSymbol, "\(sculpted)", "Sculpted")
            tile("checkmark.seal", "\(ready)", "Print-ready")
            tile("drop", String(format: "%.0f cm³", clay), "Clay used")
        }
    }

    private func tile(_ symbol: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.accent.color)
                .frame(width: 32, height: 32)
                .background(Circle().fill(theme.accent.color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(theme.ink.color)
                Text(label).font(.system(size: 11)).foregroundStyle(theme.secondaryInk.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.panel.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.panelStroke.color))
    }
}

// MARK: - Theme picker

/// Theme choice as little previews of each colourway instead of a plain segmented control.
public struct ThemePicker: View {
    @Environment(StudioThemeStore.self) private var themes
    public init() {}

    public var body: some View {
        let current = themes.current
        HStack(spacing: 6) {
            ForEach(StudioTheme.all) { t in
                let selected = t.id == current.id
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { themes.current = t }
                } label: {
                    HStack(spacing: 8) {
                        ThemeSwatch(theme: t)
                        Text(t.name).font(.system(size: 12, weight: selected ? .bold : .medium))
                    }
                    .padding(.leading, 5).padding(.trailing, 12).padding(.vertical, 5)
                    .foregroundStyle(current.ink.color)
                    .background(Capsule().fill(selected ? current.panel.color : .clear))
                    .overlay(Capsule().strokeBorder(selected ? current.accent.color : .clear, lineWidth: 2))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .help("\(t.name) theme")
            }
        }
        .padding(4)
        .background(Capsule().fill(current.panelStroke.color.opacity(current.isDark ? 0.6 : 0.5)))
    }
}

/// A tiny tile showing a theme's background, clay and accent colours.
struct ThemeSwatch: View {
    let theme: StudioTheme
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [theme.bgTop.color, theme.bgBottom.color], startPoint: .top, endPoint: .bottom))
            Circle().fill(theme.clay.color).frame(width: 13, height: 13).offset(x: -3, y: 2)
            Circle().fill(theme.accent.color).frame(width: 7, height: 7).offset(x: 6, y: -6)
        }
        .frame(width: 26, height: 26)
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.black.opacity(0.12)))
    }
}

// MARK: - Procedural cover materials

/// Procedural cover textures (no image assets needed).
enum CoverMaterialPainter {
    static func paint(_ ctx: inout GraphicsContext, size: CGSize, material: CoverMaterial, tint: RGBA) {
        let rect = CGRect(origin: .zero, size: size)
        var seed: UInt64 = 0x9E3779B97F4A7C15 &+ UInt64(material.rawValue.utf8.reduce(0) { $0 &* 31 &+ Int($1) } & 0xFFFF)
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
        let base = tint.color
        switch material {
        case .glazedCeramic:
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [tint.mix(RGBA(1, 1, 1), 0.35).color, base, tint.mix(RGBA(0, 0, 0), 0.25).color]),
                                                       startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            // Crackle glaze.
            var crackle = Path()
            for _ in 0..<26 {
                var p = CGPoint(x: rnd() * size.width, y: rnd() * size.height)
                crackle.move(to: p)
                for _ in 0..<5 {
                    p = CGPoint(x: p.x + (rnd() - 0.5) * size.width * 0.22, y: p.y + (rnd() - 0.5) * size.height * 0.16)
                    crackle.addLine(to: p)
                }
            }
            ctx.stroke(crackle, with: .color(.white.opacity(0.18)), lineWidth: 0.7)
            ctx.fill(Path(ellipseIn: CGRect(x: size.width * 0.15, y: -size.height * 0.15, width: size.width * 0.9, height: size.height * 0.45)),
                     with: .radialGradient(Gradient(colors: [.white.opacity(0.35), .clear]), center: CGPoint(x: size.width * 0.6, y: size.height * 0.05),
                                           startRadius: 0, endRadius: size.width * 0.5))
        case .matteTerracotta:
            ctx.fill(Path(rect), with: .color(base))
            var grain = Path()
            for _ in 0..<Int(size.width * size.height / 40) {
                let r = rnd() * 1.4 + 0.3
                grain.addEllipse(in: CGRect(x: rnd() * size.width, y: rnd() * size.height, width: r, height: r))
            }
            ctx.fill(grain, with: .color(.black.opacity(0.13)))
            var light = Path()
            for _ in 0..<Int(size.width * size.height / 90) {
                light.addRect(CGRect(x: rnd() * size.width, y: rnd() * size.height, width: 1, height: 1))
            }
            ctx.fill(light, with: .color(.white.opacity(0.16)))
        case .industrialAluminum:
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [tint.mix(RGBA(1, 1, 1), 0.3).color, base, tint.mix(RGBA(1, 1, 1), 0.15).color, tint.mix(RGBA(0, 0, 0), 0.15).color]),
                                                       startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            var brushed = Path()
            var y: CGFloat = 0
            while y < size.height {
                brushed.move(to: CGPoint(x: 0, y: y)); brushed.addLine(to: CGPoint(x: size.width, y: y + (rnd() - 0.5) * 2))
                y += 1.2 + rnd() * 1.4
            }
            ctx.stroke(brushed, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
            for (x, yy) in [(0.05, 0.08), (0.95, 0.08), (0.05, 0.92), (0.95, 0.92)] {
                let c = CGPoint(x: size.width * x, y: size.height * yy)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.black.opacity(0.35)))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2.5, width: 3, height: 3)), with: .color(.white.opacity(0.5)))
            }
        case .blueprintCardstock:
            ctx.fill(Path(rect), with: .color(base))
            var minor = Path(), major = Path()
            func line(_ isMajor: Bool, _ a: CGPoint, _ b: CGPoint) {
                if isMajor { major.move(to: a); major.addLine(to: b) } else { minor.move(to: a); minor.addLine(to: b) }
            }
            let step: CGFloat = 9
            for i in 0...Int(size.width / step) {
                let x = CGFloat(i) * step
                line(i % 5 == 0, CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height))
            }
            for i in 0...Int(size.height / step) {
                let y = CGFloat(i) * step
                line(i % 5 == 0, CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y))
            }
            ctx.stroke(minor, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            ctx.stroke(major, with: .color(.white.opacity(0.28)), lineWidth: 0.8)
        case .obsidianLeather:
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [tint.mix(RGBA(1, 1, 1), 0.08).color, base, tint.mix(RGBA(0, 0, 0), 0.3).color]),
                                                       startPoint: .zero, endPoint: CGPoint(x: size.width * 0.4, y: size.height)))
            var pebbles = Path()
            for _ in 0..<Int(size.width * size.height / 26) {
                let r = rnd() * 2.4 + 0.8
                pebbles.addEllipse(in: CGRect(x: rnd() * size.width, y: rnd() * size.height, width: r * 1.3, height: r))
            }
            ctx.stroke(pebbles, with: .color(.white.opacity(0.05)), lineWidth: 0.6)
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: 7, dy: 7), cornerRadius: 8), with: .color(.white.opacity(0.3)),
                       style: StrokeStyle(lineWidth: 1.1, dash: [4, 3]))
        }
    }
}
